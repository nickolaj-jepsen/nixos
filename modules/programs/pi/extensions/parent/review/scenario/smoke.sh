#!/usr/bin/env bash
# The walking skeleton: pi loads the review module, `/review` reaches the
# dispatcher, and nothing on the way leaves an extension error behind. It stays
# true as the modules land: the bare command either opens the scope picker or
# notifies what it cannot do yet.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

scenario_init smoke
scenario_fixture
scenario_start

# A broken import or a shortcut conflict shows here, before any command runs.
scenario_assert_lacks '\[Extension issues\]'

scenario_type '/review'
scenario_keys Enter
scenario_wait 'uncommitted changes|review:' 15

# Back to the composer, so the next scenario starts from pi's prompt.
scenario_keys Escape
scenario_wait 'escape interrupt|commands ·' 10
scenario_pass
