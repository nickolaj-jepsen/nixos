#!/usr/bin/env bash
# A2's acceptance: a real tuicr behind dtach, driven from the pane pi runs in.
#
# Case one is the round trip the item owns: /review suspends pi and shows tuicr;
# a mark and a save go in through the socket with no client attached; ^G returns
# to pi with its border back and no tuicr text left; a second attach that is not
# pi's shows the same review; the window is resized and a third attach draws the
# full diff pane; /review kill leaves the mark on disk and no socket behind.
#
# Case two is D12: the pi session is killed outright, so nothing tears the review
# down, and a fresh /review in a fresh pi attaches the surviving process instead
# of starting a second one.
#
# dtach is not on this checkout's PATH (its module edit is not switched in), and
# the extension looks dtach up on PATH: the tmux pane inherits the PATH exported
# here, which is how the built extensions find it.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DTACH="$(nix build nixpkgs#dtach --no-link --print-out-paths | tail -1)/bin/dtach"
[ -x "$DTACH" ] || {
  printf 'scenario: no dtach at %s\n' "$DTACH" >&2
  exit 1
}
export PATH="$(dirname "$DTACH"):$PATH"

. "$here/lib.sh"

scenario_init dtach
# A failed case must not leave a review running behind it: lib.sh's trap kills
# the tmux server, and this closes whatever review was still up.
trap 'finish_leftovers; scenario_stop' EXIT
scenario_fixture
scenario_start
scenario_assert_lacks '\[Extension issues\]'

# One review per scenario runtime dir, so the socket there is the review's.
review_socket() {
  find "${XDG_RUNTIME_DIR:-/nonexistent}/pi-review" -name '*.sock' -print -quit 2>/dev/null || true
}

# Close a review a failed case left running, and leave the mark it holds on disk.
finish_leftovers() {
  local socket pid
  socket=$(review_socket)
  [ -n "$socket" ] || return 0
  pid=$(review_pid)
  printf ':w\r' | "$DTACH" -p "$socket" 2>/dev/null || true
  if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; fi
}

wait_socket() {
  local _ found=""
  for _ in $(seq 100); do
    found=$(review_socket)
    if [ -n "$found" ]; then
      printf '%s' "$found"
      return 0
    fi
    sleep 0.2
  done
  printf 'scenario: no review socket after 20s, pane follows:\n' >&2
  scenario_pane >&2
  exit 1
}

# The review tuicr itself keeps: its pid file names the process behind the socket.
review_pid() {
  sed -n 's/.*"pid": \([0-9]*\).*/\1/p' "$XDG_DATA_HOME/tuicr/reviews/active_sessions.json" 2>/dev/null |
    tail -1
}

wait_listed() {
  local pattern="${1:?usage: wait_listed <regex>}" _ listed
  for _ in $(seq 100); do
    listed=$(tuicr review list --repo "$SCENARIO_FIXTURE" 2>/dev/null || true)
    if grep -qE -- "$pattern" <<<"$listed"; then return 0; fi
    sleep 0.2
  done
  printf "scenario: review list never matched '%s':\n" "$pattern" >&2
  tuicr review list --repo "$SCENARIO_FIXTURE" >&2 || true
  exit 1
}

# Voices the direct attaches: a shell with the scenario's environment, in the
# fixture, so `dtach -a` runs on a tty that is not pi's. Its own session, so
# killing pi's session in case two does not take this one with it.
shell_window() {
  scenario_tmux new-session -d -s attach -c "$SCENARIO_FIXTURE" "exec $SCENARIO_SHELL"
  scenario_tmux resize-window -t attach -x "$SCENARIO_COLS" -y "$SCENARIO_LINES"
}

attach_pane() {
  scenario_tmux capture-pane -p -t attach -J | sed -e 's/[[:space:]]*$//'
}

attach_lacks() {
  local pattern="${1:?usage: attach_lacks <regex>}"
  if attach_match "$pattern"; then
    printf "scenario: did not expect '%s' in the attach window, pane follows:\n" "$pattern" >&2
    attach_pane >&2
    exit 1
  fi
}

attach_match() {
  local pattern=$1 frame
  frame=$(attach_pane)
  grep -qE -- "$pattern" <<<"$frame"
}

attach_wait() {
  local pattern="${1:?usage: attach_wait <regex>}" limit="${2:-20}" _
  for _ in $(seq $((limit * 5))); do
    if attach_match "$pattern"; then return 0; fi
    sleep 0.2
  done
  printf "scenario: no match for '%s' in the attach window, pane follows:\n" "$pattern" >&2
  attach_pane >&2
  exit 1
}

# One direct attach into the shell window, and ^G back out of it.
direct_attach() {
  local cols=$1 lines=$2
  scenario_tmux resize-window -t attach -x "$cols" -y "$lines"
  scenario_tmux send-keys -t attach -l "$DTACH -a $SOCK -r winch -e '^G'"
  scenario_tmux send-keys -t attach Enter
  sleep 0.5
}

detach_direct() {
  scenario_tmux send-keys -t attach C-g
  attach_wait '\[detached\]'
}

# A bare /review with nothing live opens A1's scope picker (D11). Enter takes the
# row the cursor is on, which on this dirty fixture is "uncommitted changes": the
# scope it pins is -w, and the opener then suspends pi.
open_picked_review() {
  scenario_type '/review'
  scenario_keys Enter
  scenario_wait 'Review scope' 20
  scenario_keys Enter
}

# While a review is live, bare /review resumes it without a picker (D11).
open_live_review() {
  scenario_type '/review'
  scenario_keys Enter
}

case_one() {
  printf 'scenario: case one, the round trip\n' >&2
  open_picked_review
  SOCK=$(wait_socket)
  scenario_wait 'Files · 0/1' 25
  scenario_assert_has 'a\.ts'

  # The mark and the save, injected blind: no client is attached while pi is suspended.
  printf 'r' | "$DTACH" -p "$SOCK"
  sleep 0.3
  printf ':w\r' | "$DTACH" -p "$SOCK"
  wait_listed '"reviewed_count": 1'
  scenario_wait 'Files · 1/1' 10
  scenario_wait '✓ a\.ts' 10

  # ^G comes back to pi: its border, none of tuicr's frame.
  scenario_keys C-g
  scenario_wait 'escape interrupt|commands ·' 20
  scenario_assert_has '─{10,}'
  scenario_assert_lacks 'NORMAL|Files · 1/1|staged-and-unstaged'

  # A second attach, this time not pi's, shows the same review and the mark. At
  # 60 columns tuicr clips its own header, so the slug is not on that pane.
  shell_window
  direct_attach 60 40
  attach_wait 'NORMAL'
  attach_wait '✓ a\.ts'
  attach_lacks 'staged-and-unstaged'
  detach_direct

  # Resized to 160x50, a re-attach draws the full diff pane: the header has room
  # for the slug the narrow frame clipped.
  scenario_resize 160 50
  direct_attach 160 50
  attach_wait 'staged-and-unstaged'
  attach_wait 'git:main'
  detach_direct

  # /review kill: the save is already in, so this has to leave the mark and no socket.
  scenario_type '/review kill'
  scenario_keys Enter
  wait_listed '"reviewed_count": 1'
  wait_listed '"active": false'
  if [ -n "$(review_socket)" ]; then
    printf 'scenario: a socket is still there after /review kill: %s\n' "$(review_socket)" >&2
    exit 1
  fi
}

case_two() {
  printf 'scenario: case two, adoption after the pi session is killed outright\n' >&2
  open_picked_review
  SOCK=$(wait_socket)
  scenario_wait 'Files · 1/1' 25
  scenario_wait '✓ a\.ts' 10
  BEFORE=$(review_pid)
  [ -n "$BEFORE" ] || {
    printf 'scenario: the pid file names no review to adopt\n' >&2
    exit 1
  }

  # Killed, not shut down: no session_shutdown runs, so the review keeps going.
  kill -KILL "$(scenario_tmux list-panes -t pi -F '#{pane_pid}')"
  sleep 2
  [ -e "$SOCK" ] || {
    printf 'scenario: the review died with the session it was not supposed to\n' >&2
    exit 1
  }
  if ! kill -0 "$BEFORE" 2>/dev/null; then
    printf 'scenario: the review process %s is gone\n' "$BEFORE" >&2
    exit 1
  fi
  wait_listed '"active": true'

  # A fresh session attaches the surviving review: the same pid, the same mark.
  scenario_start
  scenario_assert_lacks '\[Extension issues\]'
  open_live_review
  scenario_wait 'Files · 1/1' 25
  # The live socket is what should keep the picker away (D11).
  scenario_assert_lacks 'Review scope'
  scenario_wait '✓ a\.ts' 10
  AFTER=$(review_pid)
  [ "$AFTER" = "$BEFORE" ] || {
    printf 'scenario: /review started a second review (%s -> %s), it should have attached %s\n' \
      "$BEFORE" "$AFTER" "$BEFORE" >&2
    exit 1
  }

  scenario_keys C-g
  scenario_wait 'escape interrupt|commands ·' 20
  scenario_type '/review kill'
  scenario_keys Enter
  wait_listed '"reviewed_count": 1'
  wait_listed '"active": false'
  [ -z "$(review_socket)" ] || {
    printf 'scenario: a socket outlived the adopted review: %s\n' "$(review_socket)" >&2
    exit 1
  }
}

case_three() {
  printf 'scenario: case three, /reload ends the review without orphaning it\n' >&2
  open_picked_review
  SOCK=$(wait_socket)
  # The same slug, and the mark the earlier cases saved, are still the review's.
  scenario_wait 'Files · 1/1' 25
  printf 'r' | "$DTACH" -p "$SOCK"
  sleep 0.3
  printf ':w\r' | "$DTACH" -p "$SOCK"
  wait_listed '"reviewed_count": 0'
  scenario_keys C-g
  scenario_wait 'escape interrupt|commands ·' 20

  # Reload tears the extension runtime down without ending the session, so the
  # review is saved and closed here rather than left running behind nothing.
  scenario_type '/reload'
  scenario_keys Enter
  scenario_wait 'Reloaded keybindings' 40
  if [ -n "$(review_socket)" ]; then
    printf 'scenario: /reload left a review socket behind: %s\n' "$(review_socket)" >&2
    exit 1
  fi
  wait_listed '"active": false'
  wait_listed '"reviewed_count": 0'

  # What the review had is on disk: the next /review reuses the same session. The
  # review is gone with the reload, so this is the picker's path again.
  open_picked_review
  SOCK=$(wait_socket)
  scenario_wait 'Files · 0/1' 25
  # Marked again, so the store ends where the acceptance reads it: one file
  # reviewed, nothing active, no socket.
  printf 'r' | "$DTACH" -p "$SOCK"
  sleep 0.3
  printf ':w\r' | "$DTACH" -p "$SOCK"
  wait_listed '"reviewed_count": 1'
  scenario_keys C-g
  scenario_wait 'escape interrupt|commands ·' 20
  scenario_type '/review kill'
  scenario_keys Enter
  wait_listed '"active": false'
  wait_listed '"reviewed_count": 1'
  [ -z "$(review_socket)" ] || {
    printf 'scenario: a socket outlived the reloaded review: %s\n' "$(review_socket)" >&2
    exit 1
  }
}

case_one
case_two
case_three
scenario_pass
