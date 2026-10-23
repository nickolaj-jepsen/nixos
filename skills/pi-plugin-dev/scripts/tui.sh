#!/usr/bin/env bash
# Drive a pi session in tmux so an extension can be observed while it runs.
#
# One session per working directory, so verbs do not need a name. The run dir
# holds the session file, captured frames and screenshots.
#
# Usage: tui.sh start|wait|cap|type|keys|resize|shot|digest|stop|ls [args]
# Output: cap prints the trimmed pane, shot prints the PNG path, digest prints
# the digest. Everything else is silent on success. Errors go to stderr, exit 1.

set -euo pipefail

outroot="${PI_PLUGIN_DEV_DIR:-$HOME/.local/share/agents/pi-plugin-dev}"
sess="plugdev-$(printf '%s' "$PWD" | sha1sum | cut -c1-8)"
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
    --) shift && break ;;
    *) break ;;
    esac
  done
  if tmux has-session -t "$sess" 2>/dev/null; then
    die "session already running for $PWD, run: tui.sh stop"
  fi
  mkdir -p "$out/sessions"
  pi_cmd="pi --session-dir $(printf '%q' "$out/sessions")"
  for arg in "$@"; do
    pi_cmd+=" $(printf '%q' "$arg")"
  done
  # A session file is required: digest reads it.
  tmux new-session -d -s "$sess" -x "$cols" -y "$lines" "PI_OFFLINE=1 $pi_cmd"
  printf '%s\n' "$out"
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
  nix run nixpkgs#charm-freeze -- -o "$target" --padding 8 --font.size "${PI_PLUGIN_DEV_FONT_SIZE:-11}" "${font_args[@]}" <"$raw" >/dev/null
  rm -f "$raw"
  printf '%s\n' "$target"
  ;;
digest)
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  file="${1:-}"
  if [ -z "$file" ]; then
    file="$(ls -t "$out"/sessions/*.jsonl 2>/dev/null | head -1)" || true
    [ -n "$file" ] || die "no session file under $out/sessions"
  fi
  exec python3 "$script_dir/digest.py" "$file"
  ;;
stop)
  tmux kill-session -t "$sess" 2>/dev/null || die "no session for $PWD"
  ;;
ls)
  tmux list-sessions -F '#{session_name} #{session_windows}w' 2>/dev/null | grep '^plugdev-' || printf '%s\n' "no sessions"
  ;;
*)
  die "usage: tui.sh start|wait|cap|type|keys|resize|shot|digest|stop|ls"
  ;;
esac
