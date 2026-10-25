set -euo pipefail

profile=personal
case "${CLAUDE_CONFIG_DIR:-}" in
  *.claude-work) profile=work ;;
esac

input=$(cat)
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
cwd=$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input")
model=$(jq -r '.model.id // empty' <<<"$input")

dim=$(printf '\033[2m')
warn=$(printf '\033[33m')
reset=$(printf '\033[0m')
green=$(printf '\033[32m')
red=$(printf '\033[31m')
cyan=$(printf '\033[36m')
branch_glyph=$'\uf418'
detached_glyph=$'\uf417'

# Last main-model response with enough output to make tokens/second meaningful.
# The transcript has no start timestamp, so the user/tool result that prompted
# it marks the start; duplicate assistant blocks share that start.
min_output=100
speed=""
if [ -n "$transcript" ] && [ -f "$transcript" ] && [ -n "$model" ]; then
  speed=$(tail -n 400 "$transcript" 2>/dev/null | jq -s -r --arg model "$model" --argjson min "$min_output" '
    def epoch:
      . as $t
      | (($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)
         + (try ($t | capture("(?<f>\\.[0-9]+)Z$").f | tonumber) catch 0));
    . as $rows
    | ([range(0; length)
        | select($rows[.].type == "assistant"
            and (($rows[.].isSidechain // false) | not)
            and ($rows[.].timestamp != null)
            and (($rows[.].message.model // "") == $model)
            and (($rows[.].message.usage.output_tokens // 0) >= $min))] | last) as $i
    | if $i == null then empty
      else
        ([range(0; $i)
          | select($rows[.].type == "user"
              and (($rows[.].isSidechain // false) | not)
              and ($rows[.].timestamp != null))] | last) as $j
        | if $j == null then empty
          else
            (($rows[$i].timestamp | epoch) - ($rows[$j].timestamp | epoch)) as $d
            | ($rows[$i].message.usage.output_tokens) as $o
            | if ($d >= 0.5 and $d <= 600) then (($o / $d) | floor) else empty end
          end
      end' 2>/dev/null) || speed=""
  case "$speed" in
    ''|*[!0-9]*) speed="" ;;
  esac
  if [ -n "$speed" ] && [ "$speed" -le 0 ]; then speed=""; fi
fi

read_step() {
  local n="" e=""
  if [ -f "$1" ]; then read -r n <"$1" || n=""; fi
  if [ -f "$2" ]; then read -r e <"$2" || e=""; fi
  if [ -n "$n" ] && [ -n "$e" ]; then printf '%s/%s' "$n" "$e"; fi
}

detect_op() {
  local gitdir=$1 op="" step next
  if [ -d "$gitdir/rebase-merge" ]; then
    op=rebase
    step=$(read_step "$gitdir/rebase-merge/msgnum" "$gitdir/rebase-merge/end")
    if [ -n "$step" ]; then op="$op $step"; fi
  elif [ -d "$gitdir/rebase-apply" ]; then
    op=rebase
    if [ -f "$gitdir/rebase-apply/applying" ]; then op=am; fi
    step=$(read_step "$gitdir/rebase-apply/next" "$gitdir/rebase-apply/last")
    if [ -n "$step" ]; then op="$op $step"; fi
  elif [ -f "$gitdir/MERGE_HEAD" ]; then op=merge
  elif [ -f "$gitdir/CHERRY_PICK_HEAD" ]; then op=cherry-pick
  elif [ -f "$gitdir/REVERT_HEAD" ]; then op=revert
  elif [ -f "$gitdir/sequencer/todo" ]; then
    while IFS= read -r next; do
      if [[ "$next" =~ ^[[:space:]]*(#|$) ]]; then continue; fi
      if [[ "$next" =~ ^[[:space:]]*(pick|p)[[:space:]] ]]; then op=cherry-pick
      elif [[ "$next" =~ ^[[:space:]]*revert[[:space:]] ]]; then op=revert
      fi
      break
    done <"$gitdir/sequencer/todo"
  fi
  printf '%s' "$op"
}

# The branch's pull request costs a network round trip, so `gh` answers in the
# background into a cache per checkout and branch, read on the next refresh.
# It is asked again when the upstream or the commits ahead of it change (a
# push), and otherwise once a minute, which catches a `gh pr create` or merge.
pr_cache=${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/pr
pr_ttl=60
# A lookup that failed (offline, auth) is not retried sooner than this.
pr_retry=20

file_age() {
  local mtime
  mtime=$(stat -c %Y "$1" 2>/dev/null) || { echo 999999; return; }
  echo $(($(date +%s) - mtime))
}

refresh_pr() {
  local top=$1 file=$2 tag=$3
  if [ -f "$file.pending" ] && [ "$(file_age "$file.pending")" -lt "$pr_retry" ]; then return 0; fi
  mkdir -p "$pr_cache"
  : >"$file.pending"
  (
    # Claude Code cancels a status line run that a newer update overtakes.
    trap '' HUP TERM
    out=$(cd "$top" && timeout 10 gh pr view --json state,isDraft 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      state=$(jq -r 'if .isDraft then "draft" else .state | ascii_downcase end' <<<"$out") || exit 0
    elif [[ "$out" == *"no pull requests found"* ]]; then
      state=none
    else
      exit 0
    fi
    printf '%s %s\n' "$tag" "$state" >"$file.tmp" && mv "$file.tmp" "$file"
    rm -f "$file.pending"
  ) </dev/null >/dev/null 2>&1 &
  disown
}

pr_glyph() {
  local top=$1 branch=$2 tag=$3 file line cached state
  file="$pr_cache/$(printf '%s\n%s' "$top" "$branch" | md5sum | cut -c1-32)"
  line=""
  if [ -f "$file" ]; then read -r line <"$file" || line=""; fi
  cached=${line%% *}
  if [ "$cached" != "$tag" ] || [ "$(file_age "$file")" -ge "$pr_ttl" ]; then
    refresh_pr "$top" "$file" "$tag"
  fi
  # The last answer stands until the next one lands: a push rarely changes it.
  state=${line#* }
  case "$state" in
    open) printf '%s' "${cyan}"$'\uf407'"${reset}" ;;
    draft) printf '%s' "${dim}"$'\uf4dd'"${reset}" ;;
    merged) printf '%s' "${green}"$'\uf419'"${reset}" ;;
    closed) printf '%s' "${red}"$'\uf4dc'"${reset}" ;;
  esac
}

# Sets git_full and git_glyph, the block with and without the branch name;
# both empty outside a repository.
git_full=""
git_glyph=""
git_segment() {
  local dir=$1
  local status line head oid ab ahead behind staged unstaged untracked conflicts upstream
  local paths gitdir top op color dirty glyph name tail arrows xy pr

  if [ -z "$dir" ]; then return 0; fi
  status=$(git --no-optional-locks -C "$dir" status --porcelain=v2 --branch 2>/dev/null) || return 0
  if [ -z "$status" ]; then return 0; fi

  head=""
  oid=""
  ab=""
  upstream=""
  ahead=0
  behind=0
  staged=0
  unstaged=0
  untracked=0
  conflicts=0
  while IFS= read -r line; do
    case "$line" in
      "# branch.head "*) head=${line:14} ;;
      "# branch.oid "*) oid=${line:13} ;;
      "# branch.upstream "*) upstream=${line:18} ;;
      "# branch.ab "*) ab=${line:12} ;;
      "1 "*|"2 "*)
        xy=${line:2:2}
        if [ "${xy:0:1}" != "." ]; then staged=$((staged + 1)); fi
        if [ "${xy:1:1}" != "." ]; then unstaged=$((unstaged + 1)); fi
        ;;
      "? "*) untracked=$((untracked + 1)) ;;
      "u "*) conflicts=$((conflicts + 1)) ;;
    esac
  done <<<"$status"

  if [ -n "$ab" ]; then
    ahead=${ab%% *}
    ahead=${ahead#+}
    behind=${ab##* }
    behind=${behind#-}
    case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac
    case "$behind" in ''|*[!0-9]*) behind=0 ;; esac
  fi

  paths=$(git --no-optional-locks -C "$dir" rev-parse --absolute-git-dir --show-toplevel 2>/dev/null) || paths=""
  gitdir=${paths%%$'\n'*}
  top=""
  if [[ "$paths" == *$'\n'* ]]; then top=${paths#*$'\n'}; fi
  op=""
  if [ -n "$gitdir" ]; then op=$(detect_op "$gitdir"); fi

  if [ -n "$op" ]; then color=$cyan
  elif [ "$unstaged" -gt 0 ] || [ "$conflicts" -gt 0 ]; then color=$red
  elif [ "$staged" -gt 0 ]; then color=$warn
  else color=$green
  fi

  if [ "$head" = "(detached)" ]; then
    glyph=$detached_glyph
    name=${oid:0:7}
  else
    glyph=$branch_glyph
    name=$head
  fi
  tail=""
  if [ "$staged" -gt 0 ] || [ "$unstaged" -gt 0 ]; then
    if [ "$unstaged" -gt 0 ]; then dirty=$red; else dirty=$warn; fi
    tail+="${dirty}*${reset}"
  fi
  # A branch that was never pushed has no pull request to look up.
  if [ "$head" != "(detached)" ] && [ -n "$upstream" ] && [ -n "$top" ]; then
    pr=$(pr_glyph "$top" "$head" "${upstream}:${ahead}")
    if [ -n "$pr" ]; then tail+=" ${pr}"; fi
  fi
  if [ -n "$op" ]; then tail+=" ${cyan}${op}${reset}"; fi
  if [ "$untracked" -gt 0 ]; then tail+=" ${warn}?${reset}"; fi
  if [ "$conflicts" -gt 0 ]; then tail+=" ${red}~${conflicts}${reset}"; fi
  if [ "$ahead" -gt 0 ] || [ "$behind" -gt 0 ]; then
    arrows=""
    if [ "$ahead" -gt 0 ]; then arrows+="⇡${ahead}"; fi
    if [ "$behind" -gt 0 ]; then arrows+="⇣${behind}"; fi
    tail+=" ${dim}${arrows}${reset}"
  fi
  git_glyph="${color}${glyph}${reset}${tail}"
  git_full=$git_glyph
  # `wt` names a worktree's folder after its branch, so the name shows only when the path doesn't say it.
  if [ -n "$name" ] && [ "$name" != "${dir##*/}" ]; then
    git_full="${color}${glyph}${reset} ${dim}${name}${reset}${tail}"
  fi
}

git_segment "$cwd"

# The janitor's cached numbers, refreshed in the background past its TTL: it is
# the only thing that knows what the agent temp root is holding.
tmp_segment=$(agent-tmp statusline 2>/dev/null) || tmp_segment=""

# The checkout's path, its last segment bright since it names the worktree.
path=""
if [ -n "$cwd" ]; then
  shown=$cwd
  case "$cwd" in
    "$HOME") shown="~" ;;
    "$HOME"/*) shown="~${cwd#"$HOME"}" ;;
  esac
  parent=""
  if [[ "$shown" == */* ]]; then parent=${shown%/*}/; fi
  path="${dim}${parent}${reset}${shown##*/}"
fi
# Git follows the path as one phrase, one space apart, as in pi's footer.
path_git=$path
if [ -n "$path" ] && [ -n "$git_full" ]; then path_git+=" "; fi
path_git+=$git_full

# Claude renders the status line with a 2-cell built-in indent, so pad to the
# width inside it and leave a 2-cell right margin.
cols=${COLUMNS:-0}
case "$cols" in
  ''|*[!0-9]*) cols=0 ;;
esac
if [ "$cols" -gt 4 ]; then target=$((cols - 4)); else target=0; fi

jq -r \
  --arg profile "$profile" \
  --arg dim "$dim" \
  --arg warn "$warn" \
  --arg reset "$reset" \
  --arg speed "$speed" \
  --arg tmp "$tmp_segment" \
  --arg pathGit "$path_git" \
  --arg git "$git_full" \
  --arg gitGlyph "$git_glyph" \
  --argjson target "$target" '
    def pct: (.context_window.used_percentage // 0);
    def vlen: gsub("\u001b\\[[0-9;]*m|\u001b\\]8;[^\u001b]*\u001b\\\\"; "") | length;
    # resets_at is epoch seconds per the docs; the ISO branch is a guard, not a known format.
    def hhmm: (if type == "number" then . else sub("\\.[0-9]+"; "") | fromdateiso8601 end)
      | strflocaltime("%H:%M");
    # Plan limits are absent on API-key sessions and before the first response.
    def limit($label; $window; $withReset):
      ($window.used_percentage // 0) as $p
      | if $p < 70 then empty
        else "\($warn)\($label) \($p | floor)%"
          + (if $withReset then (try " ↻\($window.resets_at | hhmm)" catch "") else "" end)
          + $reset
        end;
    [
      (if $profile == "work" then "\($warn)work\($reset)" else empty end),
      .model.display_name,
      (.effort.level // empty),
      (if .fast_mode then "fast" else empty end),
      (if pct > 80
       then "\($warn)\(pct)%\($reset)"
       else "\($dim)\(pct)%\($reset)" end),
      (if $speed != "" then "\($dim)\($speed) t/s\($reset)" else empty end),
      (if $tmp != "" then "\($dim)\($tmp)\($reset)" else empty end),
      limit("5h"; .rate_limits.five_hour; true),
      limit("7d"; .rate_limits.seven_day; false)
    ] | join("\($dim) · \($reset)") as $base
    | ($base | vlen) as $baseLen
    # Giving way in the order pi does: the path, then the branch name, then git.
    # The path keeps two cells from the left zone, git alone three.
    | [{text: $pathGit, min: 2}, {text: $git, min: 3}, {text: $gitGlyph, min: 3}]
    | map(select(.text != "") | .gap = ($target - $baseLen - (.text | vlen)))
    | (map(select(.gap >= .min)) | first) as $fit
    | if $target == 0 and $pathGit != "" then $base + "\($dim) · \($reset)" + $pathGit
      elif $fit then $base + (" " * $fit.gap) + $fit.text
      else $base
      end
  ' <<<"$input"
