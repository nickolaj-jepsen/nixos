# Everything the plan lists is one tab-separated line:
#   id, category, bytes, preset, title, detail
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
      printf 'jobs:%s\tjobs\t%s\t1\t%s\tjob idle %d days\n' \
        "$dir" "$size" "$dir" "$((age / 86400))"
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
      printf 'transcript:%s\ttranscripts\t%s\t1\t%s\t%d days old\n' \
        "$file" "$size" "$file" "$((age / 86400))"
    done < <(find "$root/projects" -mindepth 2 -maxdepth 3 -name '*.jsonl' -type f -print0 2>/dev/null)
  done
}

# A merged branch has every commit reachable from the default branch, so deleting
# it loses nothing. An unmerged one is offered only in `apply`, bundled first.
scan_branches() {
  local repo def branch age ahead checked
  for repo in $(repos); do
    def=$(default_branch "$repo") || continue
    checked=$(checked_out_branches "$repo")
    while IFS=$'\t' read -r branch age; do
      [ -n "$branch" ] || continue
      [ "$branch" = "$def" ] && continue
      grep -qxF -- "$branch" <<<"$checked" && continue
      if git -C "$repo" merge-base --is-ancestor -- "$branch" "$def" 2>/dev/null; then
        printf 'branch:%s|%s\tbranch\t0\t1\t%s@%s\tmerged into %s\n' \
          "$repo" "$branch" "$repo" "$branch" "$def"
        continue
      fi
      [ $((now - age)) -ge "$BRANCH_IDLE_SECONDS" ] || continue
      ahead=$(git -C "$repo" rev-list --count "$def..$branch" 2>/dev/null) || continue
      [ "${ahead:-0}" -gt 0 ] || continue
      printf 'branch:%s|%s\tbranch\t0\t0\t%s@%s\t%s commit(s) ahead, idle %s days\n' \
        "$repo" "$branch" "$repo" "$branch" "$ahead" "$(((now - age) / 86400))"
    done < <(git -C "$repo" for-each-ref --format='%(refname:short)%09%(committerdate:unix)' refs/heads 2>/dev/null)
  done
}

# wt owns what a worktree is worth: its safeToRemove already means clean tree,
# landed, not busy, not locked. Anything else is not this command's business.
scan_worktrees() {
  command -v wt >/dev/null 2>&1 || return 0
  local main name path idle size
  while IFS=$'\t' read -r main name path idle; do
    [ -n "$path" ] || continue
    size=$(size_of "$path")
    printf 'worktree:%s|%s\tworktree\t%s\t1\t%s@%s\tidle %s days\n' \
      "$main" "$name" "$size" "$main" "$name" "$((idle / 86400))"
  done < <(wt status --all 2>/dev/null |
    jq -r '.repos[] | .main as $main | .worktrees[] | select(.safeToRemove == true) |
      [$main, .name, .path, (.idleSeconds // 0)] | @tsv' 2>/dev/null)
}

# A repo is idle when nothing has been committed in it for the age, nothing is
# running inside it, and the directory itself has not been touched. The process
# check is what stops a deletion from under a dev server.
scan_build_dirs() {
  local repo last_commit dir age size
  for repo in $(repos); do
    last_commit=$(git -C "$repo" log -1 --format=%ct 2>/dev/null) || continue
    [ $((now - last_commit)) -ge "$BUILD_DIR_AGE_SECONDS" ] || continue
    anything_running_in "$repo" && continue
    while IFS= read -r -d '' dir; do
      age=$(age_of "$dir")
      [ "$age" -ge "$BUILD_DIR_AGE_SECONDS" ] || continue
      size=$(size_of "$dir")
      printf 'build:%s\tbuild\t%s\t1\t%s\trepo idle %s days, untouched %s days\n' \
        "$dir" "$size" "$dir" "$(((now - last_commit) / 86400))" "$((age / 86400))"
    done < <(find "$repo" -maxdepth 3 \( -name .git -o -name .hg -o -name .jj \) -prune -o \
      -type d \( -name node_modules -o -name .venv -o -name target -o -name dist \
      -o -name .pytest_cache -o -name __pycache__ \) -prune -print0 2>/dev/null)
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
    printf 'tmp:%s\ttmp\t%s\t1\t%s\t%s\n' "$path" "$size" "$path" "$kind"
  done
}

plan_items() {
  scan_tmp
  scan_jobs
  scan_transcripts
  scan_worktrees
  scan_build_dirs
  scan_branches
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
  export PLAN_TMP
  plan_items >"$PLAN_TMP"
}

plan_total() { awk -F'\t' '{s += $3} END {print s + 0}' "$PLAN_TMP"; }

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
    '[inputs | split("\t") |
      {id: .[0], category: .[1], bytes: (.[2] | tonumber), preset: (.[3] == "1"), title: .[4], detail: .[5]}] as $items |
     {generated: $generated,
      disk: {avail: $avail, total: $total, usedPct: $pct},
      tmp: {used: $used, budget: $budget, dead: $dead},
      reclaim: {
        bytes: (($items | map(.bytes) | add) // 0),
        count: ($items | length),
        byCategory: ($items | group_by(.category) |
          map({key: .[0].category, value: (map(.bytes) | add)}) | from_entries)
      },
      items: $items}' <"$PLAN_TMP" >"$PLAN_FILE.tmp"
  mv -f -- "$PLAN_FILE.tmp" "$PLAN_FILE"
}

# The human report: what is here, grouped, biggest first.
cmd_report() {
  build_plan
  local avail total bytes title detail count
  read -r avail total < <(free_space) || { avail=0; total=1; }
  printf 'janitor: %s free of %s on /\n' "$(gib "$avail")" "$(gib "$total")"
  for category in tmp jobs transcripts build worktree branch; do
    count=$(awk -F'\t' -v c="$category" '$2 == c {n++} END {print n + 0}' "$PLAN_TMP")
    [ "$count" -gt 0 ] || continue
    printf '\n%s (%d)\n' "$category" "$count"
    awk -F'\t' -v c="$category" '$2 == c {printf "%s\t%s\t%s\n", $3, $5, $6}' "$PLAN_TMP" |
      sort -t$'\t' -k1,1nr | head -15 |
      while IFS=$'\t' read -r bytes title detail; do
        printf '  %8s  %s  %s\n' "$(gib "$bytes")" "$title" "$detail"
      done
    if [ "$count" -gt 15 ]; then
      printf '  %8s  and %d more\n' "" "$((count - 15))"
    fi
  done
  printf '\njanitor: a pass would free %s from %s item(s). Run "just janitor apply" to pick what goes.\n' \
    "$(gib "$(plan_total)")" "$(awk 'END {print NR + 0}' "$PLAN_TMP")"
  write_plan_cache
  rm -f -- "$PLAN_TMP" "$CWD_CACHE"
}

cmd_plan_json() {
  build_plan
  write_plan_cache
  jq . "$PLAN_FILE"
  rm -f -- "$PLAN_TMP" "$CWD_CACHE"
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

apply_item() {
  local id=$1 kind=${1%%:*} rest=${1#*:} repo branch size file
  local freed_log=${PLAN_TMP:-/dev/null}.freed
  case "$kind" in
  tmp)
    [ -e "$rest" ] || return 0
    protected "$rest" && return 0
    # The plan may be minutes old; a pid-named dir is only dead while its pid is.
    case ${rest##*/} in
    '' | *[!0-9]*) ;;
    *) [ -d "/proc/${rest##*/}" ] && return 0 ;;
    esac
    size=$(size_of "$rest")
    rm -rf -- "$rest" && {
      printf '  freed   %8s  %s\n' "$(gib "$size")" "$rest"
      echo "$size" >>"$freed_log"
    }
    ;;
  jobs)
    [ -d "$rest" ] && [ "$(age_of "$rest")" -ge "$JOB_TMP_AGE_SECONDS" ] || return 0
    size=$(size_of "$rest")
    rm -rf -- "$rest" && {
      printf '  freed   %8s  %s\n' "$(gib "$size")" "$rest"
      echo "$size" >>"$freed_log"
    }
    ;;
  transcript)
    [ -f "$rest" ] && [ "$(age_of "$rest")" -ge "$TRANSCRIPT_AGE_SECONDS" ] || return 0
    size=$(file_bytes "$rest")
    rm -f -- "$rest" && {
      printf '  freed   %8s  %s\n' "$(gib "$size")" "$rest"
      echo "$size" >>"$freed_log"
    }
    ;;
  build)
    [ -d "$rest" ] && [ "$(age_of "$rest")" -ge "$BUILD_DIR_AGE_SECONDS" ] || return 0
    anything_running_in "$(dirname "$rest")" && return 0
    size=$(size_of "$rest")
    rm -rf -- "$rest" && {
      printf '  freed   %8s  %s\n' "$(gib "$size")" "$rest"
      echo "$size" >>"$freed_log"
    }
    ;;
  worktree)
    repo=${rest%%|*}
    [ -d "$repo" ] || return 0
    command -v wt >/dev/null 2>&1 || return 0
    (cd -- "$repo" && wt clean 2>&1) | sed 's/^/  /'
    ;;
  branch)
    repo=${rest%%|*}
    branch=${rest#*|}
    [ -d "$repo" ] || return 0
    git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || return 0
    checked_out_branches "$repo" | grep -qxF -- "$branch" && return 0
    if ! git -C "$repo" merge-base --is-ancestor -- "$branch" "$(default_branch "$repo")" 2>/dev/null; then
      file=$(bundle_branch "$repo" "$branch") || {
        printf '  failed  could not bundle %s@%s\n' "$repo" "$branch"
        return 0
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
  local ids_file="" have_ids=0 freed_before freed_after freed id bytes preset title detail
  local -a explicit_ids=()
  if [ "${1:-}" = --ids ]; then
    shift
    explicit_ids=("$@")
    have_ids=1
  else
    ids_file=${1:-}
  fi
  if [ "$have_ids" = 0 ] && [ -z "$ids_file" ]; then :; fi
  build_plan

  if [ "$have_ids" = 0 ] && [ -z "$ids_file" ]; then
    if [ ! -t 0 ] || ! command -v whiptail >/dev/null 2>&1; then
      printf 'janitor: needs a terminal and whiptail to pick items; run it with an ids file instead.\n' >&2
      rm -f -- "$PLAN_TMP" "$CWD_CACHE"
      return 2
    fi
    local -a args=()
    while IFS=$'\t' read -r id _ bytes preset title detail; do
      args+=("$id" "$(printf '%8s  %s  %s' "$(gib "$bytes")" "$title" "$detail")" "$([ "$preset" = 1 ] && echo ON || echo OFF)")
    done <"$PLAN_TMP"
    ids_file=$(mktemp)
    if ! whiptail --title "janitor" --checklist \
      "$(printf 'Space toggles, Enter applies. %s reclaimable; branches are bundled before deletion.' \
        "$(gib "$(plan_total)")")" \
      26 110 16 "${args[@]}" 2>"$ids_file" >/dev/null; then
      printf 'janitor: nothing selected\n'
      rm -f -- "$PLAN_TMP" "$CWD_CACHE"
  [ -n "$ids_file" ] && rm -f -- "$ids_file"
      return 0
    fi
  fi

  freed_before=$(df --output=avail -B1 / | tail -1)
  if [ "$have_ids" = 1 ]; then
    for id in ${explicit_ids[@]+"${explicit_ids[@]}"}; do
      [ -n "$id" ] && apply_item "$id"
    done
  else
    # whiptail (and a saved plan) write one id per line, quoted when it has a space.
    xargs -r -n1 <"$ids_file" 2>/dev/null |
      while IFS= read -r id; do
        [ -n "$id" ] && apply_item "$id"
      done
  fi
  freed_after=$(df --output=avail -B1 / | tail -1)
  freed=$(awk '{s += $1} END {print s + 0}' "$PLAN_TMP.freed" 2>/dev/null || echo 0)
  printf 'janitor: freed %s\n' "$(gib "$freed")"
  [ "${freed:-0}" -ge 1073741824 ] &&
    toast "Freed $(gib "$freed") of agent and repo leftovers"
  rm -f -- "$PLAN_TMP.freed"

  rm -f -- "$PLAN_TMP" "$CWD_CACHE"
  [ -n "$ids_file" ] && rm -f -- "$ids_file"
  cmd_repo_plan_refresh
  cmd_state
}

# Recompute the cached plan after a pass so the widget sees the new number.
cmd_repo_plan_refresh() {
  build_plan
  write_plan_cache
  rm -f -- "$PLAN_TMP" "$CWD_CACHE"
}

# The daily pass: merged branches, finished worktrees, transcripts, and the
# cached numbers the widget reads.
cmd_repo_pass() {
  local freed_before freed_after repo branch def checked path size removed=0
  freed_before=$(df --output=avail -B1 / | tail -1)

  for repo in $(repos); do
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
  done

  if command -v wt >/dev/null 2>&1; then
    while IFS= read -r repo; do
      [ -d "$repo" ] || continue
      (cd -- "$repo" && wt clean 2>&1) | sed 's/^/janitor: /' || true
    done < <(wt status --all 2>/dev/null |
      jq -r '.repos[] | select(.worktrees | map(select(.safeToRemove == true)) | length > 0) | .main' 2>/dev/null)
  fi

  while IFS=$'\t' read -r _ _ _ _ path _; do
    [ -f "$path" ] || continue
    [ "$(age_of "$path")" -ge "$TRANSCRIPT_AGE_SECONDS" ] || continue
    rm -f -- "$path" && printf 'janitor: removed transcript %s\n' "$path"
  done < <(scan_transcripts)

  while IFS=$'\t' read -r _ _ _ _ path _; do
    [ -d "$path" ] || continue
    [ "$(age_of "$path")" -ge "$JOB_TMP_AGE_SECONDS" ] || continue
    size=$(size_of "$path")
    rm -rf -- "$path" && printf 'janitor: removed job tmp %s (%s)\n' "$path" "$(gib "$size")"
  done < <(scan_jobs)

  freed_after=$(df --output=avail -B1 / | tail -1)
  printf 'janitor: repo pass freed %s, %d branch(es)\n' \
    "$(gib $((freed_after - freed_before)))" "$removed"
  [ $((freed_after - freed_before)) -ge 1073741824 ] &&
    toast "Freed $(gib $((freed_after - freed_before))) of agent and repo leftovers"
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
