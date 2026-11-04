#!/usr/bin/env bash
# A4's acceptance: the inbox's two surfaces, from the pane the owner sees.
#
# The comments come from scenario/fixture-inbox.ts, which appends a C1 entry the
# way the extension does, because the opener that does it for real is A2's. The
# segment is then clicked where it is drawn, the overlay is driven with j/k/y and
# resized to 60x40 and 160x50, and the whole round trip ends in a real tuicr:
# /review -w starts one on the dirty fixture, and enter in the inbox attaches the
# review that is already running instead of starting another.
#
# dtach is not on this checkout's PATH (its module edit is not switched in) and
# the extension looks dtach up on PATH, so the review half exports it here, the
# way A2's scenario does.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DTACH="$(nix build nixpkgs#dtach --no-link --print-out-paths | tail -1)/bin/dtach"
[ -x "$DTACH" ] || {
  printf 'scenario: no dtach at %s\n' "$DTACH" >&2
  exit 1
}
export PATH="$(dirname "$DTACH"):$PATH"

# `y` copies through pi, which would otherwise write the owner's real clipboard:
# with no display it takes the terminal's OSC 52 route, whose bytes stay in the
# scenario's pane. Nothing this scenario does may touch the owner's desktop.
unset DISPLAY WAYLAND_DISPLAY

. "$HERE/lib.sh"

fail() {
  printf 'scenario: %s\npane follows:\n' "$*" >&2
  scenario_pane >&2
  exit 1
}

review_socket() {
  find "${XDG_RUNTIME_DIR:-/nonexistent}/pi-review" -name '*.sock' -print -quit 2>/dev/null || true
}

# The review tuicr itself keeps: its pid file names the process behind the socket.
review_pid() {
  sed -n 's/.*"pid": \([0-9]*\).*/\1/p' \
    "$XDG_DATA_HOME/tuicr/reviews/active_sessions.json" 2>/dev/null | tail -1
}

finish_leftovers() {
  local socket
  socket=$(review_socket)
  [ -n "$socket" ] || return 0
  printf ':w\r' | "$DTACH" -p "$socket" 2>/dev/null || true
  local pid
  pid=$(sed -n 's/.*"pid": \([0-9]*\).*/\1/p' \
    "$XDG_DATA_HOME/tuicr/reviews/active_sessions.json" 2>/dev/null | tail -1)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
}

scenario_init inbox
trap 'finish_leftovers; scenario_stop' EXIT
scenario_fixture
scenario_start -e "$HERE/fixture-inbox.ts"
scenario_assert_lacks '\[Extension issues\]'
scenario_wait 'fixture: review entry 2 items' 30
# The entry is on the branch; the border paints what the session published at
# session_start, so one reload is what puts a fixture's entry in front of the
# meter. A real ingest publishes it the same way.
scenario_type '/reload'
scenario_keys Enter
scenario_wait 'fixture: review entry 2 items' 40
scenario_assert_lacks '\[Extension issues\]'

# The pane as the terminal drew it: no joining of wrapped lines, since the point
# of the assertions below is that nothing wrapped.
pane_rows() {
  scenario_tmux capture-pane -p -t pi | sed -e 's/[[:space:]]*$//'
}

# The segment's middle as `column row`. It is the last measurement on the
# editor's top border, and three columns of border tail follow it, so from the
# right edge of the row it is where the arithmetic below puts it.
segment_at() {
  local frame row line cols
  frame=$(pane_rows)
  row=$(printf '%s\n' "$frame" | grep -n 'review 2 new' | head -1 | cut -d: -f1)
  [ -n "$row" ] || fail 'the review segment is not on the border'
  line=$(printf '%s\n' "$frame" | sed -n "${row}p")
  # Columns, not bytes: the border is drawn in box characters.
  cols=$(printf '%s' "$line" | wc -m)
  printf '%s %s\n' "$((cols - 11))" "$row"
}

# A left click: the press, then the release at the same cell, which is what pi
# turns into one `click` event.
click() {
  local x=$1 y=$2
  scenario_tmux send-keys -t pi -l "$(printf '\033[<0;%s;%sM' "$x" "$y")"
  sleep 0.2
  scenario_tmux send-keys -t pi -l "$(printf '\033[<0;%s;%sm' "$x" "$y")"
}

# Every row the frame draws is a whole row: it starts and ends on its own border,
# and the bottom border carrying the keys is on screen. A row wider than the
# terminal comes back as a continuation line that starts with text, not a border.
frame_intact() {
  local frame body
  frame=$(pane_rows)
  body=$(printf '%s\n' "$frame" | sed -n '/^╭/,/^╰/p')
  [ -n "$body" ] || fail 'the overlay frame is not on the pane'
  if printf '%s\n' "$body" | grep -vE '^(╭─.*|╰─.*|│.*│)$' | grep -q .; then
    fail 'a row of the overlay wrapped instead of fitting'
  fi
  grep -qE '^╰─+ j/k move · y copy · enter review · esc close' <<<"$body" ||
    fail 'the overlay bottom border is not on screen'
}

# The segment: two comments are new and the review is 1 of 2 files through (D3, D10).
scenario_wait 'review 2 new · 1/2' 20

# The segment is a control: a click opens the same overlay /review inbox opens.
read -r CLICK_X CLICK_Y < <(segment_at)
click "$CLICK_X" "$CLICK_Y"
scenario_wait 'Review inbox' 10
scenario_assert_has 'Review inbox · 2 new'
scenario_assert_has '> src/a\.ts:42'
scenario_assert_has 'guard the empty token'
scenario_assert_has 'src/b\.ts:7-9'
scenario_assert_has 'rename this once the callers are moved'
# The overlay holds the editor's slot, so the border and its segment are gone.
scenario_assert_lacks 'review 2 new · 1/2'
frame_intact

# j and k move the highlight, and both comments stay on screen: nothing clipped.
scenario_keys j
scenario_assert_has '> src/b\.ts:7-9'
scenario_assert_has 'guard the empty token'
scenario_assert_has 'rename this once the callers are moved'
scenario_assert_has '2/2'
frame_intact
scenario_keys k
scenario_assert_has '> src/a\.ts:42'
scenario_assert_has '1/2'

# y copies the highlighted comment's location and says so.
scenario_keys y
scenario_wait 'copied src/a\.ts:42' 10

# Narrower than any desktop window, then wider: the frame is whole at both.
scenario_resize 60 40
scenario_assert_has 'Review inbox'
scenario_assert_has 'guard the empty token'
scenario_assert_has 'rename this once the callers are moved'
frame_intact
scenario_resize 160 50
scenario_assert_has 'Review inbox'
scenario_assert_has 'guard the empty token'
frame_intact

# Escape goes back to the prompt, and the segment is drawn again.
scenario_keys Escape
scenario_wait 'review 2 new · 1/2' 10
scenario_assert_lacks 'Review inbox'

# /review inbox is the other door to the same overlay.
scenario_type '/review inbox'
scenario_keys Enter
scenario_wait 'Review inbox' 10
scenario_assert_has '> src/a\.ts:42'
scenario_keys Escape
scenario_wait 'review 2 new · 1/2' 10

# A real review on the dirty fixture: -w is passed through, so no picker.
scenario_type '/review -w'
scenario_keys Enter
scenario_wait 'Files · 0/1' 30
scenario_assert_has 'a\.ts'
REVIEW_PID=$(review_pid)
[ -n "$REVIEW_PID" ] || fail 'the pid file names no review to attach'

# Back to pi; the entry A2 recorded keeps the two comments. Then enter in the
# inbox attaches the review that is running rather than starting a second one.
scenario_keys C-g
scenario_wait 'escape interrupt|commands ·' 20
scenario_assert_lacks 'Files · 0/1'
scenario_wait 'review 2 new · 0/1' 20
scenario_type '/review inbox'
scenario_keys Enter
scenario_wait 'Review inbox' 10
scenario_keys Enter
scenario_wait 'Files · 0/1' 20
scenario_assert_has 'a\.ts'
scenario_assert_lacks 'Review inbox'
ATTACHED_PID=$(review_pid)
[ "$ATTACHED_PID" = "$REVIEW_PID" ] ||
  fail "enter started a second review ($REVIEW_PID -> $ATTACHED_PID) instead of attaching $REVIEW_PID"

# Save and close, so nothing is left running behind the scenario.
scenario_keys C-g
scenario_wait 'escape interrupt|commands ·' 20
scenario_type '/review kill'
scenario_keys Enter
scenario_wait 'review: saved and closed' 20
[ -z "$(review_socket)" ] || fail "a review outlived /review kill: $(review_socket)"

scenario_pass
