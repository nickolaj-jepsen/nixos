#!/usr/bin/env bash
# A6's scenario: a replayed `flow_tour` call seeds the branch diff as tuicr
# comments authored `Flow`, records the session and the `/rv` line in FLOW.json,
# and refuses a stop whose line the diff does not contain. A real tuicr then
# opens the recorded argv in the same tmux server and renders the first stop.
set -euo pipefail

# The tuicr pane needs room for the review comments block above the diff.
SCENARIO_COLS=${SCENARIO_COLS:-200}
export SCENARIO_COLS

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

fail() {
  printf 'tour: %s\n' "$*" >&2
  exit 1
}

# The tour window's pane, read like the pi pane the harness asserts on.
tour_pane() {
  scenario_tmux capture-pane -p -t tuicr -J 2>/dev/null | sed -e 's/[[:space:]]*$//'
}

# Wait for a line in the tour window; on timeout dump it, as scenario_wait does.
tour_wait() {
  local pattern=$1 limit=${2:-20} frame
  for _ in $(seq $((limit * 5))); do
    frame=$(tour_pane)
    if grep -qE -- "$pattern" <<<"$frame"; then return 0; fi
    sleep 0.2
  done
  printf "tour: no match for '%s' after %ss, tuicr pane follows:\n" "$pattern" "$limit" >&2
  tour_pane >&2
  exit 1
}

flow_init tour
flow_fixture
# The flow's branch is named after its slug, so the fixture's feature commit is
# the diff the guide tours.
git -C "$SCENARIO_FIXTURE" checkout -q -b tour

# One fixture model for every step the scenario reaches; the judge points at a
# model this scratch catalog does not have, so its call spends no replay turn.
flow_settings '{
  "judge": {"model": "fixture/none"},
  "plan": {"model": "fixture/replay", "thinking": "high"},
  "planQuick": {"model": "fixture/replay", "thinking": "high"},
  "run": {"model": "fixture/replay", "thinking": "low"},
  "guide": {"model": "fixture/replay", "thinking": "low"}
}'

flow_start
scenario_assert_lacks '\[Extension issues\]'
scenario_assert_lacks 'Extensions failed to load'

# ── the tour call, from inside a real flow session ──────────────────────────
#
# `/flow tour` writes FLOW.json and the session's flow entry, then kicks off the
# brief skill; the replayed turn answers with the `flow_tour` call, and the
# second one asks for a line outside the diff.
scenario_type '/flow tour'
scenario_keys Enter
scenario_wait 'flow tour · brief' 20
scenario_wait 'Tour seeded\.' 40

grep -q 'comments seeded in tuicr session' "$SCENARIO_SESSIONS"/*.jsonl ||
  fail "the tool result did not report a seeded session"
grep -q 'is not a changed new line of this diff' "$SCENARIO_SESSIONS"/*.jsonl ||
  fail "the stop outside the diff was not refused"

PLAN=$(flow_plan_dir tour)
state=$(cat "$PLAN/FLOW.json")
printf 'FLOW.json tour:\n%s\n' "$(jq -c '.tour' <<<"$state")"
slug=$(jq -r '.tour.slug // ""' <<<"$state")
[ -n "$slug" ] || fail "FLOW.json recorded no tour slug"
from=$(git -C "$SCENARIO_FIXTURE" merge-base main tour)

# D24: the recorded line is the one the owner types, from the merge base.
[ "$(jq -r '.tour.rv' <<<"$state")" = "/rv -r $from..tour" ] ||
  fail "tour.rv is '$(jq -r '.tour.rv' <<<"$state")', not '/rv -r $from..tour'"
[ "$(jq -c '.tour.argv' <<<"$state")" = "[\"-r\",\"$from..tour\"]" ] ||
  fail "tour.argv is $(jq -c '.tour.argv' <<<"$state")"
[ "$(jq -r '.tour.cwd' <<<"$state")" = "$(realpath "$SCENARIO_FIXTURE")" ] ||
  fail "the tour was seeded outside the main checkout: $(jq -r '.tour.cwd' <<<"$state")"

# ── what tuicr holds ────────────────────────────────────────────────────────

comments=$(tuicr review comments --session "$slug" --repo "$SCENARIO_FIXTURE")
printf 'tuicr comments:\n%s\n' "$comments"
jq -e 'length == 3' <<<"$comments" >/dev/null ||
  fail "expected three comments (intro plus two stops), got $(jq 'length' <<<"$comments")"
jq -e 'all(.[]; .author == "Flow")' <<<"$comments" >/dev/null ||
  fail "a seeded comment is not authored Flow: $(jq -c '[.[].author]' <<<"$comments")"
jq -e '[.[].content] | index("the value is now 2")' <<<"$comments" >/dev/null ||
  fail "the first stop's text is not in the session"
jq -e '[.[].content] | index("the doubling helper is the whole feature")' <<<"$comments" >/dev/null ||
  fail "the second stop's text is not in the session"
jq -e 'any(.[]; .location == "review")' <<<"$comments" >/dev/null ||
  fail "the intro is not a review-level comment"
jq -e 'all(.[]; .lifecycle_state == "local_draft")' <<<"$comments" >/dev/null ||
  fail "a seeded comment is not a local draft"
# The refused call added nothing.
jq -e 'all(.[]; .content != "drifted past the diff")' <<<"$comments" >/dev/null ||
  fail "the stop outside the diff was stored anyway"

# ── a real tuicr on the recorded argv renders the tour ──────────────────────

mapfile -t argv < <(jq -r '.tour.argv[]' <<<"$state")
quoted=$(printf '%q ' "${argv[@]}")
cmd="cd $(printf %q "$SCENARIO_FIXTURE") && $SCENARIO_ENV tuicr $quoted --no-update-check"
scenario_tmux new-window -a -t 'pi:' -n tuicr "$cmd"
scenario_tmux resize-window -t tuicr -x "$SCENARIO_COLS" -y "$SCENARIO_LINES"
tour_wait 'the value is now 2' 30
tour_wait 'the doubling helper is the whole feature' 30

scenario_pass
