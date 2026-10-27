# Everything the plan lists is one tab-separated line:
#   id, category, bytes, preset, title, label, detail
# `title` is the path for the terminal, `label` the short form the widget shows.
# The id is what `apply` gets back, so it has to be enough to act on and to
# re-check the rule that produced it.

# Claude Code keeps a private tmp next to each job's state, and nothing removes it.
scan_jobs() {
  local jobs dir age size
  for jobs in "${CLAUDE_DIRS[@]/%//jobs}"; do
    [ -d "$jobs" ] || continue
    for dir in "$jobs"/*/tmp; do
      [ -d "$dir" ] || continue
      age=$(age_of "$dir")
      [ "$age" -ge "$JOB_TMP_AGE_SECONDS" ] || continue
      size=$(size_of "$dir")
      printf 'jobs:%s\tjobs\t%s\t1\t%s\t%s\tidle %dd\n' \
        "$dir" "$size" "$dir" "$(label_for "$dir")" "$((age / 86400))"
    done
  done
}

# pi-auto-gate's extract rebuilds the judge dataset from these, so they get a
# month. memory/ and MEMORY.md are siblings, not transcripts, and never match.
scan_transcripts() {
  local root file age size
  for root in "${CLAUDE_DIRS[@]}"; do
    [ -d "$root/projects" ] || continue
    while IFS= read -r -d '' file; do
      age=$(age_of "$file")
      [ "$age" -ge "$TRANSCRIPT_AGE_SECONDS" ] || continue
      size=$(file_bytes "$file")
      printf 'transcript:%s\ttranscripts\t%s\t1\t%s\t%s\t%dd old\n' \
        "$file" "$size" "$file" "$(label_for "$file")" "$((age / 86400))"
    done < <(find "$root/projects" -mindepth 2 -maxdepth 3 -name '*.jsonl' -type f -print0 2>/dev/null)
  done
}

# A merged branch has every commit reachable from the default branch, so deleting
# it loses nothing. An unmerged one is offered only in `apply`, bundled first.
scan_branches() {
  local repo def branch age ahead checked
  while IFS= read -r repo; do
    def=$(default_branch "$repo") || continue
    checked=$(checked_out_branches "$repo")
    while IFS=$'\t' read -r branch age; do
      [ -n "$branch" ] || continue
      [ "$branch" = "$def" ] && continue
      grep -qxF -- "$branch" <<<"$checked" && continue
      if git -C "$repo" merge-base --is-ancestor -- "$branch" "$def" 2>/dev/null; then
        printf 'branch:%s|%s\tbranch\t0\t1\t%s@%s\t%s@%s\tmerged\n' \
          "$repo" "$branch" "$repo" "$branch" "$(label_for "$repo")" "$branch"
        continue
      fi
      [ $((now - age)) -ge "$BRANCH_IDLE_SECONDS" ] || continue
      ahead=$(git -C "$repo" rev-list --count "$def..$branch" 2>/dev/null) || continue
      [ "${ahead:-0}" -gt 0 ] || continue
      printf 'branch:%s|%s\tbranch\t0\t0\t%s@%s\t%s@%s\t%s ahead · %sd\n' \
        "$repo" "$branch" "$repo" "$branch" "$(label_for "$repo")" "$branch" "$ahead" "$(((now - age) / 86400))"
    done < <(git -C "$repo" for-each-ref --format='%(refname:short)%09%(committerdate:unix)' refs/heads 2>/dev/null)
  done < <(repos)
}

# wt owns what a worktree is worth: its safeToRemove already means clean tree,
# landed, not busy, not locked. Anything else is not this command's business.
scan_worktrees() {
  command -v wt >/dev/null 2>&1 || return 0
  local main name path idle size
  while IFS=$'\t' read -r main name path idle; do
    [ -n "$path" ] || continue
    size=$(size_of "$path")
    printf 'worktree:%s|%s\tworktree\t%s\t1\t%s@%s\t%s@%s\tidle %sd\n' \
      "$main" "$name" "$size" "$main" "$name" "$(label_for "$main")" "$name" "$((idle / 86400))"
  done < <(wt list --all --json 2>/dev/null |
    jq -r '.repos[] | .main as $main | .worktrees[] | select(.safeToRemove == true) |
      [$main, .name, .path, (.idleSeconds // 0)] | @tsv' 2>/dev/null)
}

# A repo is idle when nothing has been committed in it for the age, nothing is
# running inside it, and the directory itself has not been touched. The process
# check is what stops a deletion from under a dev server.
scan_build_dirs() {
  local repo last_commit dir age size
  while IFS= read -r repo; do
    last_commit=$(git -C "$repo" log -1 --format=%ct 2>/dev/null) || continue
    [ $((now - last_commit)) -ge "$BUILD_DIR_AGE_SECONDS" ] || continue
    anything_running_in "$repo" && continue
    while IFS= read -r -d '' dir; do
      age=$(age_of "$dir")
      [ "$age" -ge "$BUILD_DIR_AGE_SECONDS" ] || continue
      size=$(size_of "$dir")
      printf 'build:%s\tbuild\t%s\t1\t%s\t%s\tidle %sd\n' \
        "$dir" "$size" "$dir" "$(label_for "$dir")" "$(((now - last_commit) / 86400))"
    done < <(find "$repo" -maxdepth 3 \( -name .git -o -name .hg -o -name .jj \) -prune -o \
      -type d \( -name node_modules -o -name .venv -o -name target -o -name dist \
      -o -name .pytest_cache -o -name __pycache__ \) -prune -print0 2>/dev/null)
  done < <(repos)
}

# Scratch entries nothing has touched for the age. Offered unticked: a stale dump
# may still be the only copy, so only a tick deletes one.
scan_scratch() {
  [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || return 0
  local entry idle
  for entry in "$SCRATCH"/* "$SCRATCH"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    idle=$(scratch_idle "$entry") || continue
    printf 'scratch:%s\tscratch\t%s\t0\t%s\t%s\tidle %dd\n' \
      "$entry" "$(size_of "$entry")" "$entry" "$(label_for "$entry")" "$((idle / 86400))"
  done
}

# Visible top-level entries of ~ the layout does not declare, one per line:
#   path, bytes, where it probably belongs
# Never in the plan's items: moving one is a decision, not a deletion.
scan_strays() {
  [ -n "$HOME_ROOTS" ] || return 0
  local entry name dest
  for entry in "$HOME"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    grep -qxF -- "$name" <<<"$HOME_ROOTS" && continue
    # shellcheck disable=SC2016 # $name is jq's, bound by --arg
    dest=$(layout --arg name "$name" '.hints[$name] // empty')
    if [ -z "$dest" ]; then
      if is_repo "$entry"; then
        dest=${REPO_PARENTS[0]}/$name
      elif [ -n "$SCRATCH" ]; then
        dest=$SCRATCH/$name
      fi
    fi
    printf '%s\t%s\t%s\n' "$entry" "$(size_of "$entry")" "$dest"
  done
}

# The dead temp dirs, in the plan like everything else: the widget shows one
# number and hands back the ids it was shown.
scan_tmp() {
  local age size kind path avail total floor_bytes over=0 low=0
  read -r avail total < <(free_space) || { avail=0; total=1; }
  floor_bytes=$((total * FREE_FLOOR_PCT / 100))
  [ "$(total_tmp_bytes)" -gt "$BUDGET_BYTES" ] && over=1
  [ "$avail" -lt "$floor_bytes" ] && low=1
  tmp_candidates | while IFS=$'\t' read -r age size kind path; do
    if ! tmp_deletable "$age" "$kind" "$size" || protected "$path"; then continue; fi
    printf 'tmp:%s\ttmp\t%s\t1\t%s\t%s\t%s\n' "$path" "$size" "$path" "$(label_for "$path")" "$kind"
  done
}

plan_items() {
  scan_tmp
  scan_jobs
  scan_transcripts
  scan_worktrees
  scan_build_dirs
  scan_branches
  scan_scratch
}

# The walk every mode shares: one process-cwd snapshot, one item list.
build_plan() {
  CWD_CACHE=$(mktemp)
  export CWD_CACHE
  {
    proc_cwds
    live_session_cwds
  } 2>/dev/null | sort -u >"$CWD_CACHE"
  PLAN_TMP=$(mktemp)
  STRAYS_TMP=$(mktemp)
  export PLAN_TMP STRAYS_TMP
  plan_items >"$PLAN_TMP"
  scan_strays >"$STRAYS_TMP"
}

# What a pass frees: the rows that start ticked. Scratch and unmerged branches
# only go when picked.
plan_total() { awk -F'\t' '$4 == 1 {s += $3} END {print s + 0}' "$PLAN_TMP"; }

write_plan_cache() {
  local avail total pct dead
  read -r avail total < <(free_space) || { avail=0; total=1; }
  pct=$((total > 0 ? (total - avail) * 100 / total : 0))
  dead=$(awk -F'\t' '$1 ~ /^tmp:/ {s += $3} END {print s + 0}' "$PLAN_TMP")
  mkdir -p -- "$STATE_DIR"
  jq -Rn \
    --argjson generated "$now" \
    --argjson avail "$avail" \
    --argjson total "$total" \
    --argjson pct "$pct" \
    --argjson budget "$BUDGET_BYTES" \
    --argjson used "$(total_tmp_bytes)" \
    --argjson dead "$dead" \
    --rawfile strays "$STRAYS_TMP" \
    --arg home "$HOME" \
    'def tilde: if startswith($home + "/") then "~" + .[($home | length):] else . end;
     [inputs | split("\t") |
      {id: .[0], category: .[1], bytes: (.[2] | tonumber), preset: (.[3] == "1"),
       title: .[4], label: .[5], detail: .[6]}] as $items |
     {generated: $generated,
      disk: {avail: $avail, total: $total, usedPct: $pct},
      tmp: {used: $used, budget: $budget, dead: $dead},
      reclaim: {
        bytes: (($items | map(select(.preset) | .bytes) | add) // 0),
        count: ($items | length),
        byCategory: ($items | group_by(.category) |
          map({key: .[0].category, value: (map(.bytes) | add)}) | from_entries)
      },
      items: $items,
      strays: [$strays | split("\n")[] | select(length > 0) | split("\t") |
        {path: .[0], bytes: (.[1] | tonumber), suggest: .[2],
         label: (.[0] | tilde), suggestLabel: (.[2] | tilde)}]}' <"$PLAN_TMP" >"$PLAN_FILE.tmp"
  mv -f -- "$PLAN_FILE.tmp" "$PLAN_FILE"
}

# The human report: what is here, grouped, biggest first.
cmd_report() {
  build_plan
  local avail total bytes title detail count
  read -r avail total < <(free_space) || { avail=0; total=1; }
  printf 'janitor: %s free of %s on /\n' "$(gib "$avail")" "$(gib "$total")"
  for category in tmp jobs transcripts build worktree branch scratch; do
    count=$(awk -F'\t' -v c="$category" '$2 == c {n++} END {print n + 0}' "$PLAN_TMP")
    [ "$count" -gt 0 ] || continue
    printf '\n%s (%d)\n' "$category" "$count"
    awk -F'\t' -v c="$category" '$2 == c {printf "%s\t%s\t%s\n", $3, $5, $7}' "$PLAN_TMP" |
      sort -t$'\t' -k1,1nr | head -15 |
      while IFS=$'\t' read -r bytes title detail; do
        printf '  %8s  %s  %s\n' "$(gib "$bytes")" "$title" "$detail"
      done
    if [ "$count" -gt 15 ]; then
      printf '  %8s  and %d more\n' "" "$((count - 15))"
    fi
  done
  count=$(awk 'END {print NR + 0}' "$STRAYS_TMP")
  if [ "$count" -gt 0 ]; then
    printf '\nstrays (%d): not part of the home layout (docs/home-layout.md); move by hand\n' "$count"
    while IFS=$'\t' read -r title bytes detail; do
      printf '  %8s  %s%s\n' "$(gib "$bytes")" "$(tilde "$title")" "${detail:+  -> $(tilde "$detail")}"
    done <"$STRAYS_TMP"
  fi
  printf '\njanitor: a pass would free %s from %s item(s). Run "just janitor apply" to pick what goes.\n' \
    "$(gib "$(plan_total)")" "$(awk 'END {print NR + 0}' "$PLAN_TMP")"
  write_plan_cache
  rm -f -- "$PLAN_TMP" "$STRAYS_TMP" "$CWD_CACHE"
}

cmd_plan_json() {
  build_plan
  write_plan_cache
  jq . "$PLAN_FILE"
  rm -f -- "$PLAN_TMP" "$STRAYS_TMP" "$CWD_CACHE"
}

# A branch is bundled before it is deleted, so `git fetch <bundle>` brings it back.
bundle_branch() {
  local repo=$1 branch=$2 dir file
  dir=$BUNDLE_DIR/$(basename "$repo")
  mkdir -p -- "$dir"
  file=$dir/${branch//\//%}.bundle
  git -C "$repo" bundle create --quiet -- "$file" "refs/heads/$branch" 2>/dev/null ||
    git -C "$repo" bundle create --quiet -- "$file" --branches="$branch" 2>/dev/null || return 1
  printf '%s\n' "$file"
}

# The temp decision, recomputed at apply time: the plan can be an hour old, and a
# path that was four days stale when it was written may have been used since.
tmp_recheck() {
  local avail total floor_bytes age size kind path over=0 low=0
  [ -n "${APPLY_TMP_SET:-}" ] && return 0
  APPLY_TMP_SET=$(mktemp)
  export APPLY_TMP_SET
  read -r avail total < <(free_space) || { avail=0; total=1; }
  floor_bytes=$((total * FREE_FLOOR_PCT / 100))
  [ "$(total_tmp_bytes)" -gt "$BUDGET_BYTES" ] && over=1
  [ "$avail" -lt "$floor_bytes" ] && low=1
  tmp_candidates | while IFS=$'\t' read -r age size kind path; do
    if tmp_deletable "$age" "$kind" "$size" && ! protected "$path"; then
      printf '%s\n' "$path"
    fi
  done >"$APPLY_TMP_SET"
}

# Whatever an id says, it has to name something the rules would free *now*, and
# something in scope: ids arrive from a checklist a user can edit and from a plan
# that may be minutes old by the time Apply is pressed.
apply_item() {
  local id=$1 kind=${1%%:*} rest=${1#*:} repo branch size file last_commit
  local freed_log=${PLAN_TMP:-/dev/null}.freed
  case "$kind" in
  tmp)
    tmp_recheck
    if ! grep -qxF -- "$rest" "$APPLY_TMP_SET"; then
      printf '  refused %s (no rule frees it any more)\n' "$rest"
      return 0
    fi
    size=$(size_of "$rest")
    rm -rf -- "$rest" && {
      printf '  freed   %8s  %s\n' "$(gib "$size")" "$rest"
      echo "$size" >>"$freed_log"
    }
    ;;
  jobs)
    in_jobs "$rest" || {
      printf '  refused %s (not a job tmp)\n' "$rest"
      return 0
    }
    [ -d "$rest" ] && [ "$(age_of "$rest")" -ge "$JOB_TMP_AGE_SECONDS" ] || return 0
    size=$(size_of "$rest")
    rm -rf -- "$rest" && {
      printf '  freed   %8s  %s\n' "$(gib "$size")" "$rest"
      echo "$size" >>"$freed_log"
    }
    ;;
  transcript)
    in_projects "$rest" || {
      printf '  refused %s (not a session transcript)\n' "$rest"
      return 0
    }
    [ -f "$rest" ] && [ "$(age_of "$rest")" -ge "$TRANSCRIPT_AGE_SECONDS" ] || return 0
    size=$(file_bytes "$rest")
    rm -f -- "$rest" && {
      printf '  freed   %8s  %s\n' "$(gib "$size")" "$rest"
      echo "$size" >>"$freed_log"
    }
    ;;
  build)
    case ${rest##*/} in
    node_modules | .venv | target | dist | .pytest_cache | __pycache__) ;;
    *)
      printf '  refused %s (not a rebuildable directory)\n' "$rest"
      return 0
      ;;
    esac
    repo=$(repo_of_path "$(dirname -- "$rest")") || {
      printf '  refused %s (not inside a repo)\n' "$rest"
      return 0
    }
    is_known_repo "$repo" || {
      printf '  refused %s (repo is not in the roster)\n' "$rest"
      return 0
    }
    [ -d "$rest" ] && [ "$(age_of "$rest")" -ge "$BUILD_DIR_AGE_SECONDS" ] || return 0
    last_commit=$(git -C "$repo" log -1 --format=%ct 2>/dev/null) || return 0
    [ $((now - last_commit)) -ge "$BUILD_DIR_AGE_SECONDS" ] || return 0
    # Checked against the repo, not the directory's parent: a dev server rooted at
    # the repo has to block a deletion inside it.
    anything_running_in "$repo" && {
      printf '  refused %s (something is running in %s)\n' "$rest" "$repo"
      return 0
    }
    size=$(size_of "$rest")
    rm -rf -- "$rest" && {
      printf '  freed   %8s  %s\n' "$(gib "$size")" "$rest"
      echo "$size" >>"$freed_log"
    }
    ;;
  scratch)
    [ -n "$SCRATCH" ] && [ "$(dirname -- "$rest")" = "$SCRATCH" ] || {
      printf '  refused %s (not a scratch entry)\n' "$rest"
      return 0
    }
    [ -e "$rest" ] || [ -L "$rest" ] || return 0
    scratch_idle "$rest" >/dev/null || {
      printf '  refused %s (touched within %d days)\n' "$rest" "$SCRATCH_AGE_DAYS"
      return 0
    }
    size=$(size_of "$rest")
    rm -rf -- "$rest" && {
      printf '  freed   %8s  %s\n' "$(gib "$size")" "$rest"
      echo "$size" >>"$freed_log"
    }
    ;;
  worktree)
    repo=${rest%%|*}
    branch=${rest#*|}
    is_known_repo "$repo" || {
      printf '  refused %s (repo is not in the roster)\n' "$rest"
      return 0
    }
    command -v wt >/dev/null 2>&1 || return 0
    # One row at a time: `wt clean` takes every finished worktree in the repo,
    # which is not the granularity the checklist just promised.
    (cd -- "$repo" && wt remove -- "$branch" 2>&1) | sed 's/^/  /'
    ;;
  branch)
    repo=${rest%%|*}
    branch=${rest#*|}
    [ -d "$repo" ] || return 0
    is_known_repo "$repo" || {
      printf '  refused %s (repo is not in the roster)\n' "$rest"
      return 0
    }
    git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || return 0
    checked_out_branches "$repo" | grep -qxF -- "$branch" && return 0
    if ! git -C "$repo" merge-base --is-ancestor -- "$branch" "$(default_branch "$repo")" 2>/dev/null; then
      file=$(bundle_branch "$repo" "$branch") || {
        printf '  failed  could not bundle %s@%s\n' "$repo" "$branch"
        return 1
      }
      printf '  bundle  %s\n' "$file"
    fi
    git -C "$repo" branch --quiet -D -- "$branch" && printf '  deleted %s@%s\n' "$repo" "$branch"
    ;;
  esac
}

# The checklist. Branches start unticked because that is the only row whose loss
# is not merely a rebuild.
cmd_apply() {
  local ids_file="" have_ids=0 freed id bytes preset title detail tag failures=0
  local -a explicit_ids=()
  local -a picked=()
  if [ "${1:-}" = --ids ]; then
    shift
    explicit_ids=("$@")
    have_ids=1
  else
    ids_file=${1:-}
  fi
  build_plan
  APPLY_TMP_SET=""

  if [ "$have_ids" = 0 ] && [ -z "$ids_file" ]; then
    if [ ! -t 0 ] || ! command -v whiptail >/dev/null 2>&1; then
      printf 'janitor: needs a terminal and whiptail to pick items; run it with an ids file instead.\n' >&2
      rm -f -- "$PLAN_TMP" "$STRAYS_TMP" "$CWD_CACHE"
      return 2
    fi
    # Whiptail tags are row numbers: a path with a space or a quote would
    # otherwise have to survive its own shell quoting on the way back.
    local -a args=()
    tag=0
    while IFS=$'\t' read -r id _ bytes preset title detail; do
      tag=$((tag + 1))
      args+=("$tag" "$(printf '%8s  %s  %s' "$(gib "$bytes")" "$title" "$detail")" "$([ "$preset" = 1 ] && echo ON || echo OFF)")
    done <"$PLAN_TMP"
    ids_file=$(mktemp)
    if ! whiptail --title "janitor" --checklist \
      "$(printf 'Space toggles, Enter applies. %s reclaimable; branches are bundled before deletion.' \
        "$(gib "$(plan_total)")")" \
      26 110 16 "${args[@]}" 2>"$ids_file" >/dev/null; then
      printf 'janitor: nothing selected\n'
      rm -f -- "$PLAN_TMP" "$STRAYS_TMP" "$CWD_CACHE" "$ids_file"
      return 0
    fi
    for tag in $(tr -d '"' <"$ids_file"); do
      case "$tag" in
      '' | *[!0-9]*) continue ;;
      esac
      picked+=("$(sed -n "${tag}p" "$PLAN_TMP" | cut -f1)")
    done
    rm -f -- "$ids_file"
    explicit_ids=(${picked[@]+"${picked[@]}"})
    have_ids=1
  fi

  # `|| failures=…` is what keeps one unremovable path from aborting the run and
  # skipping the summary; it also exempts apply_item from `set -e`.
  for id in ${explicit_ids[@]+"${explicit_ids[@]}"}; do
    [ -n "$id" ] || continue
    apply_item "$id" || failures=$((failures + 1))
  done

  freed=$(awk '{s += $1} END {print s + 0}' "$PLAN_TMP.freed" 2>/dev/null || echo 0)
  printf 'janitor: freed %s\n' "$(gib "$freed")"
  if [ "$failures" -gt 0 ]; then
    printf 'janitor: %d item(s) could not be removed\n' "$failures"
  fi
  [ "$freed" -ge 1073741824 ] && toast "Freed $(gib "$freed") of agent and repo leftovers"

  rm -f -- "$PLAN_TMP.freed" "$PLAN_TMP" "$STRAYS_TMP" "$CWD_CACHE"
  [ -n "$APPLY_TMP_SET" ] && rm -f -- "$APPLY_TMP_SET"
  cmd_repo_plan_refresh
  cmd_state
}

# Recompute the cached plan after a pass so the widget sees the new number.
cmd_repo_plan_refresh() {
  build_plan
  write_plan_cache
  rm -f -- "$PLAN_TMP" "$STRAYS_TMP" "$CWD_CACHE"
}

# The daily pass: merged branches, finished worktrees, transcripts, and the
# cached numbers the widget reads.
cmd_repo_pass() {
  local freed=0 repo branch def checked path size removed=0
  while IFS= read -r repo; do
    def=$(default_branch "$repo") || continue
    checked=$(checked_out_branches "$repo")
    while IFS= read -r branch; do
      [ -n "$branch" ] || continue
      [ "$branch" = "$def" ] && continue
      grep -qxF -- "$branch" <<<"$checked" && continue
      if git -C "$repo" branch --quiet -D -- "$branch" 2>/dev/null; then
        printf 'janitor: deleted merged branch %s@%s\n' "$repo" "$branch"
        removed=$((removed + 1))
      fi
    done < <(git -C "$repo" branch --merged "$def" --format='%(refname:short)' 2>/dev/null)
  done < <(repos)

  if command -v wt >/dev/null 2>&1; then
    while IFS= read -r repo; do
      [ -d "$repo" ] || continue
      (cd -- "$repo" && wt clean 2>&1) | sed 's/^/janitor: /' || true
    done < <(wt list --all --json 2>/dev/null |
      jq -r '.repos[] | select(.worktrees | map(select(.safeToRemove == true)) | length > 0) | .main' 2>/dev/null)
  fi

  while IFS=$'\t' read -r _ _ _ _ path _ _; do
    [ -f "$path" ] || continue
    [ "$(age_of "$path")" -ge "$TRANSCRIPT_AGE_SECONDS" ] || continue
    size=$(file_bytes "$path")
    rm -f -- "$path" && {
      freed=$((freed + size))
      printf 'janitor: removed transcript %s\n' "$path"
    }
  done < <(scan_transcripts)

  while IFS=$'\t' read -r _ _ _ _ path _ _; do
    [ -d "$path" ] || continue
    [ "$(age_of "$path")" -ge "$JOB_TMP_AGE_SECONDS" ] || continue
    size=$(size_of "$path")
    rm -rf -- "$path" && {
      freed=$((freed + size))
      printf 'janitor: removed job tmp %s (%s)\n' "$path" "$(gib "$size")"
    }
  done < <(scan_jobs)

  # Sum of what was deleted, not the df delta: other processes write while this
  # runs, and a 1.4 GB deletion that df reports as 158 MB reads like a bug.
  printf 'janitor: repo pass freed %s, %d branch(es)\n' "$(gib "$freed")" "$removed"
  [ "$freed" -ge 1073741824 ] && toast "Freed $(gib "$freed") of agent and repo leftovers"
  cmd_repo_plan_refresh
  cmd_state
}

# cwds of sessions registered as live, in case their process has wandered off.
live_session_cwds() {
  local file pid cwd
  for file in "$HOME"/.claude/sessions/*.json "$HOME"/.claude-work/sessions/*.json; do
    [ -f "$file" ] || continue
    read -r pid cwd < <(jq -r '"\(.pid // "") \(.cwd // "")"' "$file" 2>/dev/null) || continue
    [ -n "$pid" ] && [ -n "$cwd" ] && [ -d "/proc/$pid" ] || continue
    printf '%s\n' "$cwd"
  done
}

case ${1:-report} in
report) cmd_report ;;
plan) cmd_plan_json ;;
apply)
  shift
  cmd_apply "$@"
  ;;
run)
  case ${2:-tmp} in
  tmp) cmd_tmp_sweep quiet ;;
  repo) cmd_repo_pass ;;
  all)
    cmd_tmp_sweep quiet
    cmd_repo_pass
    ;;
  *)
    printf 'usage: janitor run {tmp|repo|all}\n' >&2
    exit 2
    ;;
  esac
  ;;
dir) cmd_dir "${2:-}" ;;
state) cmd_state "${2:-}" ;;
warn) cmd_warn ;;
warnline) cmd_warnline "${2:-}" ;;
*)
  printf 'usage: janitor {report|plan|apply [--ids id...|ids-file]|run {tmp|repo|all}|dir [pid]|state [print]|warn|warnline}\n' >&2
  exit 2
  ;;
esac
