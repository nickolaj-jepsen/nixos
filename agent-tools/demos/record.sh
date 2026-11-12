#!/usr/bin/env bash
# Re-records a demo GIF, demos/<name>.gif: demos/<name>.sh drives a live Claude Code session
# (agent-tools/skills/claude-mod-dev's tui.sh, so the checkout's mods) while asciinema records it, and agg
# renders the recording. A demo, not a test: a run that goes another way (the model answered
# differently, nothing showed up in time) fails and keeps the old GIF; run it again.
#
# Usage: agent-tools/demos/record.sh <name>    (or: just demo <name>)
#
# demos/<name>.sh defines `demo`, the steps, may define `setup`, called with the session's
# empty working directory to fill before it starts, and may set:
#   TUI_ARGS       extra `tui.sh start` options, e.g. (--full) for a plugin needing a connector
#   CLAUDE_ARGS    extra claude arguments, e.g. (--allowedTools ...)
#   READY_LOG      a debug-log regex to wait for before recording, e.g. an MCP server connecting
#   FORBIDDEN_LOG  a debug-log regex that fails the run and keeps the old GIF, e.g. a write tool
#   SPEED          playback speed of the GIF, default 1.8: keys can't be sent faster than a
#                  plugin's Input keeps up with, so the GIF speeds up instead
# The steps use type_slow, press, repeat, pause, wait_for and screen, defined below.
set -euo pipefail

name="${1:?usage: record.sh <name>}"
here="$(cd "$(dirname "$0")" && pwd)"
steps="$here/$name.sh"
[ -f "$steps" ] || {
  echo "no demo steps for $name: $steps" >&2
  exit 1
}
T="$(realpath "$here/../skills/claude-mod-dev/scripts/tui.sh")"

COLS=150
SPEED=1.8
ROWS=40
TUI_ARGS=()
CLAUDE_ARGS=()
READY_LOG=""
FORBIDDEN_LOG=""
# shellcheck source=/dev/null
source "$steps"

asciinema="$(nix build --no-link --print-out-paths nixpkgs#asciinema)/bin/asciinema"
agg="$(nix build --no-link --print-out-paths nixpkgs#asciinema-agg)/bin/agg"

# tui.sh names its session after $PWD, so a directory of our own keeps this one apart from
# any session driven from the checkout.
work="$(mktemp -d)"
export CLAUDE_MOD_DEV_DIR="$work/runs"
cd "$work"
sess="moddev-$(printf '%s' "$PWD" | sha1sum | cut -c1-8)"
run="$CLAUDE_MOD_DEV_DIR/$sess"

finish() {
  status=$?
  "$T" stop 2>/dev/null || true
  if [ "$status" -eq 0 ]; then
    rm -rf "$work"
  else
    echo "demo failed; the session's debug log is $run/debug.log" >&2
  fi
}
trap finish EXIT

# type_slow <text> [seconds per key]: a plugin's Input round-trips each key through its hooks
# module, so keys faster than that arrive out of order; the prompt takes the default.
type_slow() {
  local s="$1" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    # tmux reads a bare ";" argument as its command separator.
    [ "$c" = ";" ] && c='\;'
    tmux send-keys -t "$sess" -l "$c"
    sleep "${2:-0.04}"
  done
}
press() { "$T" keys "$@"; }
# repeat <count> <key> [seconds per key]: e.g. enough BSpace to empty a field.
repeat() {
  for ((i = 0; i < $1; i++)); do
    tmux send-keys -t "$sess" "$2"
    sleep "${3:-0.1}"
  done
}
pause() { sleep "$1"; }
# wait_for <regex> [seconds]: until the screen shows it; a timeout ends the run.
wait_for() { "$T" wait "$1" "${2:-20}" >/dev/null; }
screen() { "$T" cap; }

if declare -F setup >/dev/null; then
  mkdir -p "$run/cwd"
  setup "$run/cwd"
fi

# Not captured: the tmux server would inherit the pipe and hold it open.
"$T" start "${TUI_ARGS[@]}" --cols "$COLS" --lines "$ROWS" -- "${CLAUDE_ARGS[@]}" >/dev/null
tmux set -t "$sess" status off >/dev/null
tmux set -t "$sess" window-size manual >/dev/null
if [ -n "$READY_LOG" ]; then
  for _ in $(seq 60); do
    grep -qE -- "$READY_LOG" "$run/debug.log" && break
    sleep 1
  done
  grep -qE -- "$READY_LOG" "$run/debug.log" || {
    echo "the session never logged /$READY_LOG/" >&2
    exit 1
  }
fi
sleep 2

# A plain attach, not -r: tmux refuses send-keys while its only client is read-only, and a
# headless recorder sends no input of its own.
"$asciinema" rec --headless --overwrite --window-size "${COLS}x${ROWS}" -i 2 \
  -c "env -u TMUX tmux attach -f ignore-size -t $sess" "$work/raw.cast" >/dev/null 2>&1 &
rec=$!
until [ "$(tmux display -p -t "$sess" '#{session_attached}')" -gt 0 ]; do sleep 0.2; done
sleep 1

demo

tmux detach-client -s "$sess"
wait "$rec" || true

if [ -n "$FORBIDDEN_LOG" ] && grep -qE -- "$FORBIDDEN_LOG" "$run/debug.log"; then
  echo "the session logged /$FORBIDDEN_LOG/; the recording is dropped:" >&2
  grep -E -- "$FORBIDDEN_LOG" "$run/debug.log" >&2
  exit 1
fi

# Drop the detach: tmux clears the screen and prints "[detached ...]" on the way out.
n="$(grep -n 'detached (from session' "$work/raw.cast" | tail -1 | cut -d: -f1)"
[ -n "$n" ] || n=$(($(wc -l <"$work/raw.cast") + 1))
sed -n "$((n - 1))p" "$work/raw.cast" | grep -qF '[2J' && n=$((n - 1))
head -n $((n - 1)) "$work/raw.cast" >"$work/demo.cast"

font_args=()
font="$(fc-list 2>/dev/null | grep -oE '^[^:]*HackNerdFontMono-Regular\.ttf' | head -1 || true)"
[ -n "$font" ] && font_args=(--font-dir "$(dirname "$font")" --font-family "Hack Nerd Font Mono")
"$agg" "${font_args[@]}" --font-size 16 --speed "$SPEED" --idle-time-limit 1.5 --last-frame-duration 3 \
  "$work/demo.cast" "$here/$name.gif" >/dev/null 2>&1
echo "wrote $here/$name.gif"
