#!/usr/bin/env bash
set -euo pipefail

# Open Ghostty in the directory you are working in. niri spawns children with
# its own cwd ($HOME), so a bare `ghostty` from a workspace keybind lands in ~.
#
# Dir sources, in order:
#   1. the focused Ghostty's shell (after any cd)
#   2. the focused dynamic workspace's project dir, from `dirs` below (written
#      by the niri-dynamic-workspaces module)
#   3. a Ghostty on the focused workspace, whose shell the daemon started there
#   4. $HOME
#
# Only terminals are asked for a cwd: every other app has helper processes
# that chdir somewhere arbitrary, and VS Code runs every window from one
# process, so its tree cannot say which folder a window has open.

DIRS=${XDG_CONFIG_HOME:-$HOME/.config}/ghostty-here/dirs

niri_json() {
  niri msg --json "$1" 2>/dev/null || echo '{}'
}

# cwds of the processes under $1, newest process first. A terminal's active
# surface is a shell, so shells win over their children, which may have
# chdir-ed (a background job in a scratch dir).
window_cwd() {
  ps -e -o pid=,ppid=,comm= --sort=-start_time |
    awk -v root="$1" '
      { pids[NR] = $1; parent[$1] = $2; comm[$1] = $3 }
      END {
        for (i = 1; i <= NR; i++) {
          p = pids[i]
          for (q = parent[p]; q > 1; q = parent[q]) if (q == root) { print comm[p], p; break }
        }
      }' |
    while read -r comm pid; do
      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
      printf '%s %s\n' "$comm" "$cwd"
    done |
    awk '{ cwd[NR] = $2; comm[NR] = $1 }
         END {
           for (i = 1; i <= NR; i++) {
             if (comm[i] ~ /^(fish|bash|zsh|sh|dash|nu|elvish)$/) { print cwd[i]; exit }
           }
           if (NR) print cwd[1]
         }'
}

# Name of the focused workspace, falling back to the focused output's active
# one when no window is focused ($2 is the window's workspace id, 0 unknown).
workspace_name() {
  niri msg --json workspaces 2>/dev/null |
    jq -r --argjson id "$1" --arg out "$2" '
      [ .[] | select(if $id > 0 then .id == $id else (.is_focused and .output == $out) end) ]
      | .[0].name // empty' || true
}

# PIDs of the Ghostty windows on workspace $1, newest process first.
workspace_terminals() {
  niri msg --json windows 2>/dev/null |
    jq -r --argjson ws "$1" --arg app com.mitchellh.ghostty \
      '.[] | select(.workspace_id == $ws and .app_id == $app) | .pid' |
    while read -r pid; do printf '%s %s\n' "$(ps -o etimes= -p "$pid")" "$pid"; done |
    sort -n | awk '{ print $2 }' || true
}

focused=$(niri_json focused-window)
app_id=$(jq -r '.app_id // empty' <<<"$focused")
window_pid=$(jq -r '.pid // empty' <<<"$focused")
workspace_id=$(jq -r '.workspace_id // 0' <<<"$focused")

dir=""
if [[ $app_id == com.mitchellh.ghostty && -n $window_pid ]]; then
  dir=$(window_cwd "$window_pid")
fi

if [[ -z $dir ]]; then
  output=$(niri_json focused-output | jq -r '.name // empty')
  # niri-dynamic-workspaces names workspaces "<prefix><key>[ <title>]"; the key
  # indexes the project dirs.
  key=$(workspace_name "$workspace_id" "$output")
  key=${key#dyn-}
  key=${key%% *}
  if [[ -n $key && -r $DIRS ]]; then
    dir=$(awk -v k="$key" '$1 == k { print $2; exit }' "$DIRS" || true)
  fi
fi

# Template workspaces have no dirs entry; the terminal the daemon spawned there
# carries the dir the template resolved.
if [[ -z $dir && $workspace_id != 0 ]]; then
  mapfile -t pids < <(workspace_terminals "$workspace_id")
  for p in "${pids[@]}"; do
    [[ $p == "$window_pid" ]] && continue
    dir=$(window_cwd "$p")
    [[ -n $dir ]] && break
  done
fi

[[ -d $dir ]] || dir=$HOME
exec ghostty --working-directory="$dir" "$@"
