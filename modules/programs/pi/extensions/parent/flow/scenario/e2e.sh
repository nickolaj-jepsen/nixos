#!/usr/bin/env bash
# The walking skeleton for /flow: both packages load under the scenario harness,
# the flow skills are shipped and hidden, and `/flow` answers. Every step after
# the brief is PENDING until the conductor lands; A7 turns this into a drive
# from brief to done.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

flow_init e2e
flow_fixture
flow_start

# A broken import, a package that does not load, or a command clash shows here.
scenario_assert_lacks '\[Extension issues\]'
scenario_assert_lacks 'Extensions failed to load'

# The skills ship through parent/package.json's pi field and reach the session
# as /skill:<name> commands.
scenario_type '/flow skeleton'
scenario_keys Enter
scenario_wait 'plan PENDING' 20
scenario_assert_has 'flow skeleton'
scenario_assert_has 'run PENDING'
scenario_assert_has 'guide PENDING'
scenario_assert_has 'done PENDING'
# The skills reach the session through parent/package.json's pi field, which is
# all-or-nothing: a missing `skills` entry leaves this list empty.
scenario_type '/skill:flow'
scenario_wait 'skill:flow-plan' 10
scenario_keys Escape
scenario_pass
