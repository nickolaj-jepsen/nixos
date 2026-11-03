#!/usr/bin/env bash
# A6's claim between two pi sessions in one repository (U8, D7, D11): the first
# `/review take` takes the repository, a second session is told whose it is and
# takes it over deliberately, and a claim left behind by a session that is gone
# blocks nobody. The claim file is read straight off disk, since that is what
# the other harness reads too.
#
# The hub's wait reason is A6's unit case: it goes to the hub's socket, which no
# pane shows, and a review holds pi's event loop while it runs.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

scenario_init claim
scenario_fixture
# The hub judges liveness from the registries Claude Code keeps; this scenario's
# sessions register in a registry of their own, never in the owner's.
mkdir -p "$SCENARIO_ROOT/claude/sessions"
SCENARIO_ENV+=" CLAUDE_CONFIG_DIR=$(printf %q "$SCENARIO_ROOT/claude")"

ROOT=$(realpath "$SCENARIO_FIXTURE")
CLAIM="$SCENARIO_AGENT/review-claims/$(printf %s "$ROOT" | sha256sum | cut -c1-16).json"

# --- one pi per tmux session, each with its own pane log -----------------
# lib.sh's scenario_start starts the single session its own scenarios need; this
# one needs two pi sessions in one repository, and then a third after one of
# them is gone, so each pi gets a tmux session of its own.
open_session() {
  local name=$1 ext cmd
  ext=$(scenario_extensions)
  cmd="cd $(printf %q "$SCENARIO_FIXTURE") && $SCENARIO_ENV exec pi --no-extensions -e $(printf %q "$ext/parent") --session-dir $(printf %q "$SCENARIO_SESSIONS")"
  scenario_tmux new-session -d -s "$name" -x "$SCENARIO_COLS" -y "$SCENARIO_LINES" "$cmd"
  scenario_tmux pipe-pane -t "$name" -o "cat > $SCENARIO_ROOT/$name.log"
  pane_wait "$name" 'escape interrupt|commands ·' 20
}

pane() {
  scenario_tmux capture-pane -p -t "${1:?session}" -J | sed -e 's/[[:space:]]*$//'
}

# The pane into a variable first: `capture-pane | grep -q` kills the capture
# with SIGPIPE once grep has its answer, and under pipefail that reads as a miss.
pane_wait() {
  local target=$1 pattern=$2 limit=${3:-20} frame _
  for _ in $(seq $((limit * 5))); do
    frame=$(pane "$target")
    if grep -qE -- "$pattern" <<<"$frame"; then
      return 0
    fi
    sleep 0.2
  done
  printf "claim: no match for '%s' in session %s after %ss, pane follows:\n" \
    "$pattern" "$target" "$limit" >&2
  pane "$target" >&2
  exit 1
}

pane_assert_lacks() {
  local frame
  frame=$(pane "$1")
  if grep -qE -- "$2" <<<"$frame"; then
    printf "claim: did not expect '%s' in session %s, pane follows:\n" "$2" "$1" >&2
    pane "$1" >&2
    exit 1
  fi
}

ask() {
  scenario_tmux send-keys -t "$1" -l -- "$2"
  scenario_tmux send-keys -t "$1" Enter
}

claim_field() {
  if [ ! -f "$CLAIM" ]; then
    printf 'claim: no claim file at %s\n' "$CLAIM" >&2
    exit 1
  fi
  node -e 'const claim = require(process.argv[1]); process.stdout.write(String(claim[process.argv[2]] ?? ""))' \
    "$CLAIM" "$1"
}

assert_claim() {
  local field=$1 want=$2 got
  got=$(claim_field "$field")
  if [ "$got" != "$want" ]; then
    printf 'claim: expected %s=%s, got %s; file follows:\n' "$field" "$want" "$got" >&2
    cat "$CLAIM" >&2
    exit 1
  fi
}

# --- the first session takes the repository -------------------------------
open_session one
ask one '/review take'
pane_wait one 'review: you hold the claim' 15
pane_assert_lacks one 'review: claimed by'

assert_claim root "$ROOT"
SESSION_ONE=$(claim_field session)
PID_ONE=$(claim_field pid)
[ -n "$SESSION_ONE" ] || {
  printf 'claim: no session recorded\n' >&2
  exit 1
}
kill -0 "$PID_ONE" 2>/dev/null || {
  printf 'claim: the claim names pid %s, which is not running\n' "$PID_ONE" >&2
  exit 1
}

# --- a second session in the same repository is told whose it is ----------
open_session two
ask two '/review take'
pane_wait two "review: claimed by session ${SESSION_ONE:0:8} \\(pid ${PID_ONE}\\); took over" 15
SESSION_TWO=$(claim_field session)
PID_TWO=$(claim_field pid)
[ "$SESSION_TWO" != "$SESSION_ONE" ] || {
  printf 'claim: the takeover kept the first session (%s)\n' "$SESSION_ONE" >&2
  exit 1
}
[ "$PID_TWO" != "$PID_ONE" ] || {
  printf 'claim: the takeover kept pid %s\n' "$PID_ONE" >&2
  exit 1
}
kill -0 "$PID_TWO" 2>/dev/null || {
  printf 'claim: the takeover names pid %s, which is not running\n' "$PID_TWO" >&2
  exit 1
}

# --- a claim whose session is gone blocks nobody --------------------------
# The second session is killed outright, as a crashed pi would be, so its
# registry entry and its pid are both stale.
scenario_tmux kill-session -t two
for _ in $(seq 50); do
  kill -0 "$PID_TWO" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$PID_TWO" 2>/dev/null; then
  printf 'claim: session two (pid %s) survived its tmux session\n' "$PID_TWO" >&2
  exit 1
fi
# The claim file outlives the session; only the staleness rule frees the repo.
assert_claim session "$SESSION_TWO"

open_session three
ask three '/review take'
pane_wait three 'review: you hold the claim' 15
pane_assert_lacks three 'review: claimed by'
SESSION_THREE=$(claim_field session)
[ "$SESSION_THREE" != "$SESSION_TWO" ] || {
  printf 'claim: the third session did not take the stale claim (%s)\n' "$SESSION_TWO" >&2
  exit 1
}
kill -0 "$(claim_field pid)" 2>/dev/null || {
  printf 'claim: the third session did not record its own running pid\n' >&2
  exit 1
}

scenario_pass
