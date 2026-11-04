#!/usr/bin/env bash
# A5: C5's batch prefilled above the owner's draft on `/review send`, the inbox
# emptied by the submit that carries the batch's marker line, and the entry
# read back from the branch by /reload (D4, C1, U2).
#
# The review entry comes from scenario/fixture-review.ts, which appends one the
# way the extension does, because the opener that does it for real is A2's. The
# turn that the submit starts runs on the replay provider, so the scratch agent
# dir needs no credentials and the input handler still runs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

REPLAY=${PI_REPLAY_PROVIDER:-$HOME/.agents/skills/pi-plugin-dev/assets/fixture-provider.ts}
[ -f "$REPLAY" ] || {
  printf 'scenario: no replay provider at %s; set PI_REPLAY_PROVIDER\n' "$REPLAY" >&2
  exit 1
}

fail() {
  printf 'scenario: %s\npane follows:\n' "$*" >&2
  scenario_pane >&2
  exit 1
}

scenario_init batch
scenario_fixture

# The submitted batch is a real prompt, so the session needs a model.
printf '[{"text":"noted"}]\n' >"$SCENARIO_ROOT/turns.json"
SCENARIO_ENV+=" FIXTURE=$(printf %q "$SCENARIO_ROOT/turns.json")"

scenario_start -e "$HERE/fixture-review.ts" -e "$REPLAY" --provider fixture --model replay
scenario_assert_lacks '\[Extension issues\]'
scenario_wait 'fixture: review entry 1 \(sent 0\)' 30

# The draft the owner had typed. prompt-store keeps it for this session, which
# is how `/review send` can still put the batch above it: pi empties the editor
# before an extension command runs.
scenario_type 'please also update the docs'
sleep 1
scenario_assert_has 'please also update the docs'

# One client, so the clear and the command are adjacent: the flow D4 describes.
scenario_tmux send-keys -t pi C-c \
  \; send-keys -t pi -l -- '/review send' \
  \; send-keys -t pi Enter

scenario_wait 'Review comments from tuicr' 20
scenario_assert_has 'review: 1 comment prefilled'
scenario_assert_has '1\. `a\.ts:1` \[issue\] fixture comment 1'
scenario_assert_has 'please also update the docs'

pane=$(scenario_pane)
batch_line=$(printf '%s\n' "$pane" | grep -n 'Review comments from tuicr' | head -1 | cut -d: -f1)
draft_line=$(printf '%s\n' "$pane" | grep -n 'please also update the docs' | head -1 | cut -d: -f1)
[ -n "$batch_line" ] && [ -n "$draft_line" ] && [ "$batch_line" -lt "$draft_line" ] ||
  fail "the batch is not above the draft (batch ${batch_line:-absent}, draft ${draft_line:-absent})"

# Enter delivers it: the marker line in the submitted prompt clears the inbox, and
# the border segment the owner reads stops saying anything is new (D3, D4).
scenario_keys Enter
scenario_wait 'noted' 20
scenario_wait 'review 0/1' 20
scenario_assert_lacks 'review 1 new'
scenario_type '/review send'
scenario_keys Enter
scenario_wait 'review: no comments to send' 20

# /reload rebuilds the review from the branch: the sent list survived, and the
# comment the fixture appended on the way back is the only pending one.
scenario_type '/reload'
scenario_keys Enter
scenario_wait 'fixture: review entry 2 \(sent 1\)' 40
scenario_type '/review send'
scenario_keys Enter
scenario_wait '1\. `a\.ts:2` \[issue\] fixture comment 2' 20
scenario_assert_lacks 'review: 2 comments prefilled'

scenario_pass
