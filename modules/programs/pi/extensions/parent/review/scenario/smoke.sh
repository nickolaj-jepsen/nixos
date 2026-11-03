#!/usr/bin/env bash
# G0's walking skeleton: pi loads the review module, `/review` reaches the
# dispatcher, and nothing on the way leaves an extension error behind.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

scenario_init smoke
scenario_fixture
scenario_start

# A broken import or a shortcut conflict shows here, before any command runs.
scenario_assert_lacks '\[Extension issues\]'

scenario_type '/review'
scenario_keys Enter
scenario_wait 'review: not implemented yet' 15
scenario_pass
