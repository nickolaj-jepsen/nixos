#!/usr/bin/env bash
# A2's scenario: a real pi opens the approval page on a real HANDOFF.md, the
# owner changes the mode, the run model, the final reviewer, one item's tier
# and Q1 on it, and approves — and a second flow sends the plan back with a note.
#
# What it proves beyond the unit tests: the overlay really opens inside pi and
# takes the keys, the edits land where D13 says (FLOW.json's mode and run
# settings, the item's `Tier:` line, one dated Amendments entry), the run
# session starts on the model the page chose, APPROVAL.md is on disk, and a
# send-back puts its note into the plan session without leaving the step.
set -euo pipefail

# A wide terminal on purpose: the page's rows carry an item's whole title.
SCENARIO_COLS=${SCENARIO_COLS:-200}
export SCENARIO_COLS

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

fail() {
  printf 'approval: %s\n' "$*" >&2
  exit 1
}

flow_init approval
flow_fixture
# The flow's branch is named after its slug, so the fixture's commits are its diff.
git -C "$SCENARIO_FIXTURE" checkout -q -b approval

# Every session step runs on a fixture model; the judge points at a model this
# scratch catalog does not have, so its call fails at once and spends no replay
# turn — the turns file is one global order across all five sessions.
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

# ── brief → plan: the picker, as A1's conductor shows it ────────────────────

PLAN=$(flow_plan_dir approval)
mkdir -p "$PLAN"
printf '# Brief\n\nThe fixture brief: one file changes.\n' >"$PLAN/BRIEF.md"

scenario_type '/flow approval'
scenario_keys Enter
scenario_wait 'Brief written. Advancing.' 30
scenario_wait 'Plan step \(the judge suggests' 30
scenario_keys Enter
scenario_wait 'Plan written.' 30
scenario_wait 'flow approval · plan' 20

# ── plan → approve: the page opens on the parsed handoff ────────────────────

cp "$FLOW_SCENARIO_DIR/../handoff-example.md" "$PLAN/HANDOFF.md"
scenario_type '/flow next'
scenario_keys Enter
scenario_wait 'Approval: approval' 30
scenario_assert_has 'The dashboard prints a table'
scenario_assert_has 'Mode  gated'
# The cursor opens on approve, so a blind enter approves; that row is drawn off
# the top of a tall page, so the edit rows are reached by their keys.
# The page's own content is on disk before anything is answered.
[ -s "$PLAN/APPROVAL.md" ] || fail "the page wrote no APPROVAL.md"
for id in G0 A1 S1; do
  grep -q "^- $id " "$PLAN/APPROVAL.md" || fail "APPROVAL.md does not list $id"
done
grep -q '(unverified)' "$PLAN/APPROVAL.md" || fail "APPROVAL.md does not flag the unverified acceptance"

# ── the owner edits on the page: mode, run model, one tier, Q1 ──────────────

# m: the mode row; right cycles gated → deviation.
scenario_keys m
scenario_keys Right
scenario_wait 'Mode  deviation' 10
# r: the run model row; enter edits it, enter keeps what was typed.
scenario_keys r
scenario_keys Enter
scenario_type 'fixture/deep'
scenario_keys Enter
scenario_wait 'Run model  fixture/deep' 10
# f: the final reviewer, a role-key setting; enter edits it, enter keeps it.
scenario_keys f
scenario_keys Enter
scenario_type 'reviewer'
scenario_keys Enter
scenario_wait 'Final review role  reviewer *($|[^-])' 10
# t: the first item's tier row; right takes it to deep.
scenario_keys t
scenario_keys Right
scenario_wait 'G0 The writer  tier: deep' 10
# q: Q1; enter types the answer, enter keeps it.
scenario_keys q
scenario_keys Enter
scenario_type 'report-2026-03.csv is the filename'
scenario_keys Enter
scenario_wait 'report-2026-03.csv is the filename' 10

# ── approve, and the run session starts on what the page chose ──────────────

scenario_keys a
scenario_keys Enter
scenario_wait 'Run finished.' 30
scenario_wait 'flow approval · run' 20

state=$(cat "$PLAN/FLOW.json")
printf 'FLOW.json after approval:\n%s\n' "$state"
jq -e '.step == "run"' <<<"$state" >/dev/null || fail "the flow did not move to the run step"
jq -e '.mode == "deviation"' <<<"$state" >/dev/null || fail "the page's mode was not written"
jq -e '.settings.run == {"model": "fixture/deep", "thinking": "low"}' <<<"$state" >/dev/null ||
  fail "the page's run settings were not written"
# Only the field the owner changed: the default thinking level is not frozen as theirs.
jq -e '.settings.finalReview == {"role": "reviewer"}' <<<"$state" >/dev/null ||
  fail "the page's final reviewer was not written"

# The run session really ran on the model the page chose.
chain=$(flow_chain)
printf 'chain (file, parent, model, thinking):\n%s\n' "$chain"
mapfile -t models < <(flow_chain | cut -f3)
[ "${#models[@]}" -eq 3 ] || fail "expected three sessions, found ${#models[@]}"
[ "${models[2]}" = "fixture/deep" ] || fail "the run session ran on '${models[2]}'"

handoff=$(cat "$PLAN/HANDOFF.md")
deep=$(grep -c '^- Tier: deep$' <<<"$handoff" || true)
[ "$deep" -eq 1 ] || fail "expected exactly one deep tier, found $deep"
# G0 is the item the page retiered; the other two are untouched.
awk '/^### G0 /{on=1} /^### A1 /{on=0} on' <<<"$handoff" | grep -q '^- Tier: deep$' ||
  fail "the page did not retier G0"
grep -q '^- Tier: flash$' <<<"$handoff" || fail "the untouched tiers lost their value"

# One dated Amendments entry, from the page, carrying the answer.
grep -Eq '^- [0-9]{4}-[0-9]{2}-[0-9]{2}, owner, approval page: Q1 answered: report-2026-03\.csv is the filename$' \
  <<<"$handoff" || fail "the answer is not in ## Amendments: $(sed -n '/## Amendments/,$p' <<<"$handoff")"
# The entry sits under the Amendments heading the plan already had.
sed -n '/## Amendments/,$p' <<<"$handoff" | grep -q 'Q1 answered' || fail "the entry is not under Amendments"
# The plan still parses, so the run lead reads the same plan the page showed.
updated=$(cat "$PLAN/HANDOFF.md")
grep -q '^## Budget$' <<<"$updated" || fail "the rewritten handoff lost a section"

# ── send back: the note reaches the plan session, and the step stays ────────

scenario_type '/new'
scenario_keys Enter
scenario_wait 'New session started' 20
# The brief is on disk before the flow starts: its step advances at once.
PLAN2=$(flow_plan_dir second)
mkdir -p "$PLAN2"
printf '# Brief\n\nAnother fixture brief.\n' >"$PLAN2/BRIEF.md"
scenario_type '/flow second'
scenario_keys Enter
scenario_wait 'Second brief written. Advancing.' 30
scenario_wait 'Plan step \(the judge suggests' 30
scenario_keys Enter
scenario_wait 'Plan written again.' 30
cp "$FLOW_SCENARIO_DIR/../handoff-example.md" "$PLAN2/HANDOFF.md"
scenario_type '/flow next'
scenario_keys Enter
scenario_wait 'Approval: second' 30

# s: the send-back row; enter types the note, enter sends it.
scenario_keys s
scenario_keys Enter
scenario_type 'split A1 into the button and its test'
scenario_keys Enter
# A send-back re-asks the plan choice, preselected on what the plan step already
# runs on; enter keeps it, so the note goes into the same plan session and no
# step is closed.
scenario_wait 'Plan step after the send-back' 30
scenario_keys Enter
scenario_wait 'sent back to the plan step' 30
scenario_wait 'Revising the plan.' 30

state2=$(cat "$PLAN2/FLOW.json")
jq -e '.step == "plan"' <<<"$state2" >/dev/null || fail "a sent-back plan left the plan step"
jq -e '.pending == null' <<<"$state2" >/dev/null || fail "a sent-back plan queued a run session"
jq -e '.settings == {} and .mode == null' <<<"$state2" >/dev/null ||
  fail "a send-back froze the page's settings or mode into FLOW.json"
grep -rl 'split A1 into the button and its test' "$SCENARIO_SESSIONS"/*.jsonl >/dev/null ||
  fail "the note never reached the plan session"

scenario_pass
