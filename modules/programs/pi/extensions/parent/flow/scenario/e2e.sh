#!/usr/bin/env bash
# The walking skeleton for /flow: both packages load under the scenario harness,
# the flow skills are shipped and hidden, `/flow` starts a flow, its brief step
# runs in a new linked session and the footer names it. A7 turns this into a
# drive from brief to done.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

flow_init e2e
flow_fixture
flow_start

# A broken import or a package that does not load shows here, before any command.
scenario_assert_lacks '\[Extension issues\]'
scenario_assert_lacks 'Extensions failed to load'

# `/flow <slug>` starts a flow in this session and sends the brief skill at it,
# which is the only step that runs where the flow was started.
scenario_type '/flow skeleton'
scenario_keys Enter
scenario_wait 'flow skeleton · brief' 30
scenario_assert_has 'skill name="flow-brief"'
scenario_assert_has 'brief done|flow skeleton · brief'

# The skills reach the session through parent/package.json's pi field, which is
# all-or-nothing: a missing `skills` entry leaves this list empty.
scenario_type '/skill:flow'
scenario_wait 'skill:flow-plan' 10
scenario_keys Escape
scenario_pass
