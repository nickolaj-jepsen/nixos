#!/usr/bin/env bash
# A1's scenario: a real pi drives one flow from brief to done on the replay
# provider, then a second one whose plan model does not exist.
#
# What it proves, beyond the unit tests: the session chain is linked by
# parentSession, each session really ran on its step's model and thinking level,
# every finished step recorded a cost, a second `flow_next` in one turn advanced
# nothing, and a step whose model does not resolve leaves pi running with an
# error instead of dying.
set -euo pipefail

# A wide terminal on purpose: the footer gives up its status segments before it
# gives up the path, and this scratch path is long (D18 is asserted below).
SCENARIO_COLS=${SCENARIO_COLS:-200}
export SCENARIO_COLS

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

fail() {
  printf 'transitions: %s\n' "$*" >&2
  exit 1
}

# Wait for a pattern; if it has not arrived, press Enter once and wait again.
# The plan → run page approves without a key while it is G0's stub, and is a TUI
# overlay (A2) that needs one.
wait_or_enter() {
  local pattern=$1 limit=${2:-30} _
  for _ in $(seq $((limit * 5))); do
    scenario_match "$pattern" && return 0
    sleep 0.2
  done
  scenario_keys Enter
  scenario_wait "$pattern" "$limit"
}

flow_init transitions
flow_fixture
# The flow's branch is named after its slug, so the fixture's commits give it a
# diff to measure.
git -C "$SCENARIO_FIXTURE" checkout -q -b transitions

# Every session step runs on a fixture model; the judge points at a model this
# scratch catalog does not have, so its call fails at once and spends no replay
# turn (the turns below are in one global order).
flow_settings '{
  "judge": {"model": "fixture/none"},
  "plan": {"model": "fixture/deep", "thinking": "high"},
  "planQuick": {"model": "fixture/replay", "thinking": "high"},
  "run": {"model": "fixture/replay", "thinking": "low"},
  "guide": {"model": "fixture/replay", "thinking": "low"}
}'

flow_start
scenario_assert_lacks '\[Extension issues\]'
scenario_assert_lacks 'Extensions failed to load'

# ── brief → plan: the agent asks twice, the owner confirms the judge's pick ──

PLAN=$(flow_plan_dir transitions)
mkdir -p "$PLAN"
printf '# Brief\n\nThe fixture brief: one file changes.\n' >"$PLAN/BRIEF.md"

scenario_type '/flow transitions'
scenario_keys Enter
scenario_wait 'Brief written. Advancing.' 30
scenario_wait 'Plan step \(the judge suggests' 30
scenario_keys Enter

# ── plan → approve → run ────────────────────────────────────────────────────

scenario_wait 'Plan written.' 30
# The footer names the flow and its step (D18).
scenario_wait 'flow transitions · plan' 20

cp "$FLOW_SCENARIO_DIR/../handoff-example.md" "$PLAN/HANDOFF.md"
scenario_type '/flow next'
scenario_keys Enter
wait_or_enter 'Run finished.' 30

# ── run → guide, gated: every gate stops the run ────────────────────────────

scenario_wait 'flow transitions · run' 20
scenario_type '/flow next'
scenario_keys Enter
scenario_wait 'Move to the guide' 20
scenario_keys Enter
scenario_wait 'Review guide written.' 30
scenario_wait 'flow transitions · guide' 20

# ── guide → done ────────────────────────────────────────────────────────────

scenario_type '/flow next'
scenario_keys Enter
scenario_wait 'flow transitions: done' 20

# ── what the four sessions prove ────────────────────────────────────────────

# Session file, its header's parentSession, its last model_change, its last
# thinking_level_change, oldest first.
chain=$(flow_chain)
printf 'chain (file, parent, model, thinking):\n%s\n' "$chain"
mapfile -t files < <(flow_chain | cut -f1)
mapfile -t parents < <(flow_chain | cut -f2)
mapfile -t models < <(flow_chain | cut -f3)
mapfile -t levels < <(flow_chain | cut -f4)
[ "${#files[@]}" -eq 4 ] || fail "expected four sessions, found ${#files[@]}"
[ "${parents[0]}" = "-" ] || fail "the first session has a parent: ${parents[0]}"
[ "$(basename "${parents[1]}")" = "${files[0]}" ] || fail "plan is not linked to the brief: ${parents[1]}"
[ "$(basename "${parents[2]}")" = "${files[1]}" ] || fail "run is not linked to the plan: ${parents[2]}"
[ "$(basename "${parents[3]}")" = "${files[2]}" ] || fail "guide is not linked to the run: ${parents[3]}"
[ "${models[1]} ${levels[1]}" = "fixture/deep high" ] || fail "plan ran on '${models[1]} ${levels[1]}'"
[ "${models[2]} ${levels[2]}" = "fixture/replay low" ] || fail "run ran on '${models[2]} ${levels[2]}'"
[ "${models[3]} ${levels[3]}" = "fixture/replay low" ] || fail "guide ran on '${models[3]} ${levels[3]}'"

# The duplicate flow_next in one turn was answered, not obeyed.
grep -q 'already advancing' "$SCENARIO_SESSIONS"/*.jsonl ||
  fail "the repeated flow_next was not answered with 'already advancing'"
# flow_status answered from a real session: its JSON carries the budget.
grep -q 'linesCap' "$SCENARIO_SESSIONS"/*.jsonl || fail "flow_status answered no budget"
grep -q 'spentStep' "$SCENARIO_SESSIONS"/*.jsonl || fail "flow_status answered no step spend"
grep -q 'reviewer-deep' "$SCENARIO_SESSIONS"/*.jsonl || fail "flow_status answered no roles"

state=$(cat "$PLAN/FLOW.json")
printf 'FLOW.json:\n%s\n' "$state"
jq -e '.step == "done"' <<<"$state" >/dev/null || fail "the flow did not reach done"
jq -e '.mode == "gated" and .quick == false' <<<"$state" >/dev/null || fail "mode or plan stage"
jq -e '.base == "main" and .branch == "transitions"' <<<"$state" >/dev/null || fail "base or branch"
jq -e '[.steps[].step] == ["brief", "plan", "run", "guide"]' <<<"$state" >/dev/null ||
  fail "the step records are not brief, plan, run, guide"
jq -e 'all(.steps[]; (.cost | type) == "number" and (.endedAt | type) == "number")' <<<"$state" >/dev/null ||
  fail "a finished step has no cost or no end"
jq -e '.judge | length == 2' <<<"$state" >/dev/null || fail "the judge did not record two verdicts"
jq -e '[.judge[].at] == ["brief", "handoff"]' <<<"$state" >/dev/null || fail "the judge verdicts' places"
jq -e '.pending == null' <<<"$state" >/dev/null || fail "a pending step survived"

# ── a step whose model does not resolve ─────────────────────────────────────

scenario_type '/new'
scenario_keys Enter
scenario_wait 'New session started' 20
PLAN2=$(flow_plan_dir second)
scenario_type '/flow second'
scenario_keys Enter
scenario_wait 'Second brief written.' 30
scenario_wait 'flow second · brief' 20
mkdir -p "$PLAN2"
printf '# Brief\n\nAnother fixture brief.\n' >"$PLAN2/BRIEF.md"
# A hand-edited FLOW.json: this flow's plan model is not in the catalog.
jq '.settings = {"plan": {"model": "fixture/nope", "thinking": "high"}}' \
  "$PLAN2/FLOW.json" >"$PLAN2/FLOW.json.tmp"
mv "$PLAN2/FLOW.json.tmp" "$PLAN2/FLOW.json"

scenario_type '/flow next'
scenario_keys Enter
scenario_wait 'Plan step \(the judge suggests' 20
scenario_keys Enter
scenario_wait 'is not in the catalog' 30
scenario_assert_has 'fixture/nope'

# pi is still alive and the step is still pending: the next command is answered.
scenario_tmux has-session -t pi || fail "pi died on the unresolvable model"
scenario_type '/flow next'
scenario_keys Enter
scenario_wait 'never started' 20

state2=$(cat "$PLAN2/FLOW.json")
jq -e '.step == "plan"' <<<"$state2" >/dev/null || fail "the failed step is not the plan step"
jq -e '.pending.model == "fixture/nope"' <<<"$state2" >/dev/null || fail "pending was not kept for a retry"
jq -e '[.steps[].step] == ["brief"]' <<<"$state2" >/dev/null || fail "a plan session was recorded anyway"

scenario_pass
