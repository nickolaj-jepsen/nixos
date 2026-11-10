#!/usr/bin/env bash
set -euo pipefail

# Open an agent note in the desktop's editor, else print the path.

if [[ $# -ne 1 ]]; then
  echo "usage: agent-note-open <path>" >&2
  exit 2
fi
if [[ ! -f $1 ]]; then
  echo "agent-note-open: no such file: $1" >&2
  exit 1
fi
path=$(realpath -s -- "$1")
# editor-open is only on a Linux desktop; elsewhere the bare CLI is all there is.
if command -v editor-open >/dev/null; then
  exec editor-open "$path"
fi
if command -v code >/dev/null; then
  exec code --reuse-window "$path"
fi
echo "$path"
