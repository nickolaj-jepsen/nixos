#!/usr/bin/env bash
# The flow's walking skeleton, end to end: one real pi starts a flow, its brief
# session ends the step, the owner confirms the plan pick, the approval overlay
# opens on a real HANDOFF.md and approves, the run stops at the gated gate, the
# guide seeds the tour, and the flow ends at done — with no step left pending.
#
# The replay model stands in for every step, so this proves the machinery, not
# the prompts. `e2e.turns.json` is one global order across the four sessions
# (notes/testing.md §3): the brief calls `flow_next` itself, as `flow-brief`
# tells it to, and the guide calls `flow_tour` and then `flow_next`, as
# `flow-guide` tells it to.
set -euo pipefail

# A wide terminal on purpose: the approval page's rows carry an item's title,
# and the footer gives up its status segments before the path.
SCENARIO_COLS=${SCENARIO_COLS:-200}
export SCENARIO_COLS

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

fail() {
  printf 'e2e: %s\n' "$*" >&2
  exit 1
}

flow_init e2e
flow_fixture
# The flow's branch is named after its slug, so the fixture's feature commit is
# the diff the guide tours.
git -C "$SCENARIO_FIXTURE" checkout -q -b e2e

# Every session step runs on a fixture model; the judge points at a model this
# scratch catalog does not have, so its call fails at once and spends no replay
# turn. The turns below are in one global order.
flow_settings '{
  "judge": {"model": "fixture/none"},
  "plan": {"model": "fixture/deep", "thinking": "high"},
  "planQuick": {"model": "fixture/replay", "thinking": "high"},
  "run": {"model": "fixture/replay", "thinking": "low"},
  "guide": {"model": "fixture/replay", "thinking": "low"}
}'

flow_start

# A broken import or a package that does not load shows here, before any command.
scenario_assert_lacks '\[Extension issues\]'
scenario_assert_lacks 'Extensions failed to load'

# ── brief: the existing session writes BRIEF.md and ends the step ────────────

PLAN=$(flow_plan_dir e2e)
mkdir -p "$PLAN"
printf '# Brief\n\nThe fixture brief: one file changes.\n' >"$PLAN/BRIEF.md"

scenario_type '/flow e2e'
scenario_keys Enter
scenario_wait '\[skill\] flow-brief' 20
scenario_wait 'Plan step \(the judge suggests' 30
scenario_assert_has 'flow e2e · brief'

# ── plan: the owner confirms the judge's pick, the plan writes HANDOFF.md ────

scenario_keys Enter
scenario_wait 'Plan written.' 30
scenario_wait 'flow e2e · plan' 20

cp "$FLOW_SCENARIO_DIR/../handoff-example.md" "$PLAN/HANDOFF.md"

# ── approve: the page opens on the parsed plan and approves ─────────────────

scenario_type '/flow next'
scenario_keys Enter
scenario_wait 'Approval: e2e' 30
scenario_assert_has 'Mode  gated'
[ -s "$PLAN/APPROVAL.md" ] || fail "the approval page wrote no APPROVAL.md"
scenario_keys a
scenario_keys Enter

# ── run: the replay lead finishes and the gate stops the flow ───────────────

scenario_wait 'Run finished.' 30
scenario_wait 'flow e2e · run' 20
scenario_wait 'Move to the guide' 20
scenario_keys Enter
scenario_wait 'flow e2e · guide' 20

# ── guide: the replay guide writes the guide and seeds the tour ─────────────

scenario_wait 'Review guide written.' 30
scenario_wait 'flow e2e: done' 30

# ── what the run left ──────────────────────────────────────────────────────

scenario_assert_lacks 'PENDING'
scenario_assert_lacks 'Extension issues'

state=$(cat "$PLAN/FLOW.json")
printf 'FLOW.json:\n%s\n' "$state"
jq -e '.step == "done"' <<<"$state" >/dev/null || fail "the flow did not reach done"
jq -e '.mode == "gated" and .quick == false' <<<"$state" >/dev/null || fail "mode or plan stage"
jq -e '.pending == null' <<<"$state" >/dev/null || fail "a pending step survived"
jq -e '[.steps[].step] == ["brief", "plan", "run", "guide"]' <<<"$state" >/dev/null ||
  fail "the step records are not brief, plan, run, guide"
jq -e 'all(.steps[]; (.cost | type) == "number" and (.endedAt | type) == "number")' <<<"$state" >/dev/null ||
  fail "a finished step has no cost or no end"
jq -e '.judge | length == 2' <<<"$state" >/dev/null || fail "the judge did not record two verdicts"

# The guide seeded the branch diff as a tour the owner reopens with /rv (D17,
# D24), from the merge base to the flow's branch.
from=$(git -C "$SCENARIO_FIXTURE" merge-base main e2e)
jq -e --arg rv "/rv -r $from..e2e" '.tour.rv == $rv' <<<"$state" >/dev/null ||
  fail "tour.rv is '$(jq -r '.tour.rv // ""' <<<"$state")', not '/rv -r $from..e2e'"
slug=$(jq -r '.tour.slug // ""' <<<"$state")
[ -n "$slug" ] || fail "FLOW.json recorded no tour slug"
tuicr review comments --session "$slug" --repo "$SCENARIO_FIXTURE" | jq -e 'length == 3' >/dev/null ||
  fail "the tour is not seeded in tuicr session $slug"

# Four linked sessions, each on its step's model and level (A1's chain, proved
# once more through the approval page rather than around it).
chain=$(flow_chain)
printf 'chain (file, parent, model, thinking):\n%s\n' "$chain"
mapfile -t files < <(flow_chain | cut -f1)
mapfile -t parents < <(flow_chain | cut -f2)
mapfile -t models < <(flow_chain | cut -f3)
[ "${#files[@]}" -eq 4 ] || fail "expected four sessions, found ${#files[@]}"
[ "$(basename "${parents[1]}")" = "${files[0]}" ] || fail "plan is not linked to the brief"
[ "$(basename "${parents[2]}")" = "${files[1]}" ] || fail "run is not linked to the plan"
[ "$(basename "${parents[3]}")" = "${files[2]}" ] || fail "guide is not linked to the run"
[ "${models[1]}" = "fixture/deep" ] || fail "plan ran on '${models[1]}'"
[ "${models[2]}" = "fixture/replay" ] || fail "run ran on '${models[2]}'"

scenario_pass
