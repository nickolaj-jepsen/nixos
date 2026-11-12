#!/usr/bin/env bash
set -euo pipefail

# Toggle a floating zed window on one reused markdown file, kept in nirius's scratchpad:
# hidden on the bottom-most workspace, shown on the focused one, hidden again when it is
# focused. The niri window rule that floats it matches the title zed opens a lone file
# with, "scratch.md"; once loaded zed retitles it "scratch.md — scratch.md", its
# single-file worktree then the file.

# ZED_SCRATCH_FILE moves it; the basename must stay scratch.md for the matches.
file=${ZED_SCRATCH_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/scratch/scratch.md}
match=(--app-id '^dev\.zed\.Zed$' --title '^scratch\.md( |$)')

# Shows it, or hides it again when it is the focused window.
nirius scratchpad-show "${match[@]}" >/dev/null 2>&1 && exit

mkdir -p "$(dirname "$file")"
[[ -e $file ]] || : >"$file"
zeditor "$file"
# No such window: zed is opening it, so put the window niriusd learns about where zed
# left it. Only registered windows get here; a window niriusd has lost is not rescued.
for _ in $(seq 100); do
  nirius scratchpad-toggle --no-move "${match[@]}" >/dev/null 2>&1 && exit
  sleep 0.05
done
echo "zed-scratch: no zed window for $file" >&2
exit 1
