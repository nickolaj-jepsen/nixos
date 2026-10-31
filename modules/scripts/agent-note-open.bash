#!/usr/bin/env bash
set -euo pipefail

# Open an agent note for reading: rendered by glow in its own Ghostty window
# (niri floats it by app id) under Wayland, else in VS Code, else print the path.
# annotate-plan's PLAN.md is edited, not read, so it always goes to VS Code.

if [[ $# -ne 1 ]]; then
  echo "usage: agent-note-open <path>" >&2
  exit 2
fi
if [[ ! -f $1 ]]; then
  echo "agent-note-open: no such file: $1" >&2
  exit 1
fi
path=$(realpath -s -- "$1")
dir=${path%/*}

# annotate-plan copies the plan to PLAN.prev.md after every write.
edit=false
[[ ${path##*/} == PLAN.md && -e $dir/PLAN.prev.md ]] && edit=true

if ! $edit && [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v ghostty >/dev/null; then
  # `-e` runs no shell and must come last; store paths keep it independent of the caller's PATH.
  # Without confirm-close-surface=false, closing the window asks first because less is still running.
  PAGER="$(command -v less) -R" setsid -f ghostty --class=dev.fireproof.notes \
    --title="${dir##*/}/${path##*/}" --confirm-close-surface=false \
    -e "$(command -v glow)" -p "$path" \
    </dev/null >/dev/null 2>&1
  exit 0
fi
if command -v code >/dev/null; then
  exec code --reuse-window "$path"
fi
echo "$path"
