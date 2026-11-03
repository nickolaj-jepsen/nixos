#!/usr/bin/env bash
# A1's picker in a real pi on a fixture checkout: D1's seven rows, the reason a
# row cannot be picked (no origin/HEAD, no parent commit, a clean tree), the
# cursor skipping those rows, and escape or enter closing the overlay onto the
# composer it covered.
#
# The rows themselves are asserted here rather than in G0's smoke, which is
# where the plan first put them (HANDOFF Amendments). Pass-through argv, the
# streaming refusal and the `-p` rule are A1's unit cases: they leave nothing on
# the pane that a capture could prove, and B2 is a deep-equal on argv.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

scenario_init picker
scenario_fixture
scenario_start

# A broken import or a shortcut conflict shows here, before any command runs.
scenario_assert_lacks '\[Extension issues\]'

# --- a dirty checkout with one commit and no remote -----------------------
# The uncommitted row is the one to pick, the branch row has no origin/HEAD and
# the last-commit row has no parent to compare against.
scenario_type '/review'
scenario_keys Enter
scenario_wait 'Review scope' 15
scenario_assert_has 'enter review'
for row in \
  'uncommitted changes' \
  'branch vs origin/HEAD' \
  'last commit' \
  "tuicr's commit picker" \
  'every tracked file' \
  'pull request' \
  'custom revset'; do
  scenario_assert_has "$row"
done
scenario_assert_has 'no origin/HEAD'
scenario_assert_has 'no parent commit'
scenario_assert_has '› uncommitted changes'

# Two rows down is "every tracked file": the cursor stepped over the branch and
# last-commit rows because neither can be picked here.
scenario_keys j
scenario_keys j
scenario_wait '› every tracked file' 5

# Escape leaves the picker, and the composer is back.
scenario_keys Escape
sleep 0.5
scenario_assert_lacks 'Review scope'

# --- the same checkout with the change committed --------------------------
# Nothing uncommitted is left, so that row says so, and the commit gives the
# last-commit row a parent: it becomes the first row the cursor can land on.
git -C "$SCENARIO_FIXTURE" -c user.email=review@example.invalid -c user.name=Review \
  commit -qam "committed before the second look"
scenario_type '/review'
scenario_keys Enter
scenario_wait 'Review scope' 15
scenario_assert_has 'the working tree is clean'
scenario_assert_has '› last commit'

# Enter hands the pinned scope to the opener and the overlay closes.
scenario_keys Enter
sleep 0.5
scenario_assert_lacks 'Review scope'

# --- a diff filter is not a scope -----------------------------------------
# -p only narrows the diff, so an argv of nothing else has no identity to pin
# and says so instead of starting a session that cannot be resumed.
scenario_type '/review -p a.ts'
scenario_keys Enter
scenario_wait 'review: -p only filters the diff; name a scope too' 15
scenario_assert_lacks 'Review scope'

scenario_pass
