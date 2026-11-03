#!/usr/bin/env bash
set -euo pipefail

# Open an agent note for reading: in the bar's note reader where there is one, else in
# VS Code, else print the path. annotate-plan's PLAN.md is edited, not read, so it always
# goes to VS Code.

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

if ! $edit && command -v agent-hub >/dev/null && agent-hub show "$path"; then
  exit 0
fi
if command -v code >/dev/null; then
  exec code --reuse-window "$path"
fi
echo "$path"
