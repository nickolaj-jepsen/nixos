#!/usr/bin/env bash
# Drive a Claude Code session in tmux so a mod can be observed while it runs.
#
# One session per working directory, so verbs do not need a name. The run dir
# holds the debug log, captured frames, screenshots and the directory the
# session runs in.
#
# Usage: tui.sh start|wait|cap|type|keys|resize|shot|log|stop|ls [args]
# Output: cap prints the trimmed pane, shot prints the PNG path, log prints the
# debug log's lines about plugins. Everything else is silent on success. Errors
# go to stderr, exit 1.

set -euo pipefail

if [ -n "${CLAUDE_MOD_DEV_DIR:-}" ]; then
  outroot="$CLAUDE_MOD_DEV_DIR"
elif [ -d .agents/tmp ]; then
  outroot="$(realpath .agents/tmp)/claude-mod-dev"
else
  outroot="$HOME/.local/state/claude-mod-dev"
fi
sess="moddev-$(printf '%s' "$PWD" | sha1sum | cut -c1-8)"
out="$outroot/$sess"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

need_session() {
  tmux has-session -t "$sess" 2>/dev/null || die "no session for $PWD, run: tui.sh start"
}

pane() {
  tmux capture-pane -p -t "$sess" "$@" | sed -e 's/[[:space:]]*$//'
}

cmd="${1:-}"
shift || true

case "$cmd" in
start)
  cols=120
  lines=36
  cwd=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --cols)
      cols="$2"
      shift 2
      ;;
    --lines)
      lines="$2"
      shift 2
      ;;
    --cwd)
      cwd="$(realpath "$2")"
      shift 2
      ;;
    --) shift && break ;;
    *) break ;;
    esac
  done
  if tmux has-session -t "$sess" 2>/dev/null; then
    die "session already running for $PWD, run: tui.sh stop"
  fi
  # Its own directory by default: the session's transcript then lands under a
  # project of its own, away from the checkout's history.
  own_cwd=""
  [ -n "$cwd" ] || own_cwd=1 cwd="$out/cwd"
  mkdir -p "$out" "$cwd"
  : >"$out/debug.log"
  # claude-dev loads the mods from their checkout; without it, name the folder
  # yourself with --plugin-dir after `--`.
  bin=claude
  command -v claude-dev >/dev/null 2>&1 && bin=claude-dev
  claude_cmd="$bin --debug-file $(printf '%q' "$out/debug.log")"
  for arg in "$@"; do
    claude_cmd+=" $(printf '%q' "$arg")"
  done
  # AGENT_HUB_HIDDEN: a test session stays off the agent hub's bar.
  tmux new-session -d -s "$sess" -x "$cols" -y "$lines" -c "$cwd" "AGENT_HUB_HIDDEN=1 $claude_cmd"
  # Return only once the TUI accepts input, so callers can drive it straight
  # away. A new directory asks whether to trust it first; only the driver's
  # own empty one is answered for you.
  for _ in $(seq 150); do
    frame="$(pane 2>/dev/null || true)"
    if printf '%s' "$frame" | grep -q 'Yes, I trust this folder'; then
      [ -n "$own_cwd" ] || die "Claude Code asks whether to trust $cwd: answer it with tui.sh keys, or trust the folder first"
      tmux send-keys -t "$sess" Down Enter
      sleep 1
    elif printf '%s' "$frame" | grep -qE '^❯|shift\+tab to cycle|\? for shortcuts'; then
      printf '%s\n' "$out"
      exit 0
    fi
    sleep 0.2
  done
  printf '%s\n' "session did not reach the prompt after 30s, pane follows:" >&2
  pane >&2 || true
  exit 1
  ;;
wait)
  pattern="${1:?usage: tui.sh wait <regex> [seconds]}"
  limit="${2:-20}"
  need_session
  for _ in $(seq $((limit * 5))); do
    if pane | grep -qE -- "$pattern"; then
      pane
      exit 0
    fi
    sleep 0.2
  done
  printf '%s\n' "no match for '$pattern' after ${limit}s, pane follows:" >&2
  pane >&2
  exit 1
  ;;
cap)
  need_session
  frame="$(pane "$@")"
  mkdir -p "$out"
  printf '%s\n' "$frame" >"$out/frame.txt"
  printf '%s\n' "$frame"
  ;;
type)
  need_session
  [ $# -gt 0 ] || die "usage: tui.sh type <text>"
  tmux send-keys -t "$sess" -l -- "$*"
  ;;
keys)
  need_session
  [ $# -gt 0 ] || die "usage: tui.sh keys <key...>"
  tmux send-keys -t "$sess" -- "$@"
  # Escape and the next byte within a few milliseconds read as alt+<key>.
  case " $* " in *" Escape "*) sleep 0.3 ;; esac
  ;;
resize)
  need_session
  tmux resize-window -t "$sess" -x "${1:?cols}" -y "${2:?lines}"
  ;;
shot)
  need_session
  mkdir -p "$out"
  target="${1:-$out/shot-$(date +%H%M%S).png}"
  raw="$(mktemp)"
  tmux capture-pane -e -p -t "$sess" >"$raw"
  # freeze's own font resolution misses Nerd Font glyphs, but a PUA glyph is
  # still legible as a box next to a readable cap, so this is best effort.
  font="$(fc-list 2>/dev/null | grep -oE '/nix/store/[^:]*HackNerdFont-Regular\.ttf' | head -1 || true)"
  font_args=()
  [ -n "$font" ] && font_args=(--font.file "$font")
  nix run nixpkgs#charm-freeze -- -o "$target" --padding 8 --font.size "${CLAUDE_MOD_DEV_FONT_SIZE:-11}" "${font_args[@]}" <"$raw" >/dev/null
  rm -f "$raw"
  printf '%s\n' "$target"
  ;;
log)
  [ -f "$out/debug.log" ] || die "no debug log under $out"
  # With no pattern: what the engine said about the folders it loaded from disk.
  grep -E -- "${1:-@inline|\(user, |plugin-dir watch|did not load|skipped|refused|threw|bypassed|does not validate}" "$out/debug.log" | tail -n "${2:-40}" || printf '%s\n' "no matching lines"
  ;;
stop)
  tmux kill-session -t "$sess" 2>/dev/null || die "no session for $PWD"
  ;;
ls)
  tmux list-sessions -F '#{session_name} #{session_windows}w' 2>/dev/null | grep '^moddev-' || printf '%s\n' "no sessions"
  ;;
*)
  die "usage: tui.sh start|wait|cap|type|keys|resize|shot|log|stop|ls"
  ;;
esac
