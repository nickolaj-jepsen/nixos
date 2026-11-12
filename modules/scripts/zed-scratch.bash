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

exists() {
  niri msg --json windows | jq -e \
    'any(.[]; .app_id == "dev.zed.Zed" and (.title | test("^scratch\\.md( |$)")))' >/dev/null
}

# Fails only when no registered window matches.
nirius scratchpad-show "${match[@]}" >/dev/null 2>&1 && exit

# A window niriusd does not know yet: zed restored it, or the daemon restarted.
if exists; then
  nirius scratchpad-toggle --no-move "${match[@]}" >/dev/null
  exec nirius scratchpad-show "${match[@]}" >/dev/null
fi

mkdir -p "$(dirname "$file")"
[[ -e $file ]] || : >"$file"
zeditor "$file"
for _ in $(seq 100); do
  if exists; then
    exec nirius scratchpad-toggle --no-move "${match[@]}" >/dev/null
  fi
  sleep 0.05
done
echo "zed-scratch: no zed window for $file" >&2
exit 1
