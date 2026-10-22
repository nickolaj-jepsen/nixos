set -euo pipefail

profile=personal
case "${CLAUDE_CONFIG_DIR:-}" in
  *.claude-work) profile=work ;;
esac

input=$(cat)
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
cwd=$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input")
model=$(jq -r '.model.id // empty' <<<"$input")
worktree=$(jq -r '.workspace.git_worktree // empty' <<<"$input")

dim=$(printf '\033[2m')
warn=$(printf '\033[33m')
reset=$(printf '\033[0m')
green=$(printf '\033[32m')
red=$(printf '\033[31m')
cyan=$(printf '\033[36m')
branch_glyph=$'\uf418'
detached_glyph=$'\uf417'
worktree_glyph=$'\uf1bb'

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

git_segment() {
  local dir=$1 wt=$2
  local status line head oid ab ahead behind staged unstaged untracked conflicts
  local gitdir op step color dirty glyph name out arrows xy

  if [ -z "$dir" ]; then return 0; fi
  status=$(git --no-optional-locks -C "$dir" status --porcelain=v2 --branch 2>/dev/null) || return 0
  if [ -z "$status" ]; then return 0; fi

  head=""
  oid=""
  ab=""
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

  gitdir=$(git --no-optional-locks -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || gitdir=""
  op=""
  if [ -n "$gitdir" ]; then op=$(detect_op "$gitdir"); fi

  if [ -n "$op" ]; then color=$cyan
  elif [ "$unstaged" -gt 0 ] || [ "$conflicts" -gt 0 ]; then color=$red
  elif [ "$staged" -gt 0 ]; then color=$warn
  else color=$green
  fi

  out=""
  if [ -n "$wt" ]; then out+="${dim}${worktree_glyph}${reset} "; fi
  if [ "$head" = "(detached)" ]; then
    glyph=$detached_glyph
    name=${oid:0:7}
  else
    glyph=$branch_glyph
    name=$head
  fi
  out+="${color}${glyph}${reset}"
  if [ -n "$name" ]; then out+=" ${dim}${name}${reset}"; fi
  if [ "$staged" -gt 0 ] || [ "$unstaged" -gt 0 ]; then
    if [ "$unstaged" -gt 0 ]; then dirty=$red; else dirty=$warn; fi
    out+="${dirty}*${reset}"
  fi
  if [ -n "$op" ]; then out+=" ${cyan}${op}${reset}"; fi
  if [ "$untracked" -gt 0 ]; then out+=" ${warn}?${reset}"; fi
  if [ "$conflicts" -gt 0 ]; then out+=" ${red}~${conflicts}${reset}"; fi
  if [ "$ahead" -gt 0 ] || [ "$behind" -gt 0 ]; then
    arrows=""
    if [ "$ahead" -gt 0 ]; then arrows+="⇡${ahead}"; fi
    if [ "$behind" -gt 0 ]; then arrows+="⇣${behind}"; fi
    out+=" ${dim}${arrows}${reset}"
  fi
  printf '%s' "$out"
}

git_seg=$(git_segment "$cwd" "$worktree")

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
  --arg git "$git_seg" \
  --argjson target "$target" '
    def pct: (.context_window.used_percentage // 0);
    def vlen: gsub("\u001b\\[[0-9;]*m"; "") | length;
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
      limit("5h"; .rate_limits.five_hour; true),
      limit("7d"; .rate_limits.seven_day; false)
    ] | join("\($dim) · \($reset)") as $base
    | if $git == "" then $base
      else
        ($base | vlen) as $baseLen
        | ($git | vlen) as $gitLen
        | ($target - $baseLen - $gitLen) as $gap
        | if $target > 0 and $gap >= 2
          then $base + (" " * $gap) + $git
          else $base + "\($dim) · \($reset)" + $git
          end
      end
  ' <<<"$input"
