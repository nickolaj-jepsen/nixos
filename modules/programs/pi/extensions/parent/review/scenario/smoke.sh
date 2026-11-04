#!/usr/bin/env bash
# The walking skeleton: pi loads the review module, `/rv` reaches tuicr, and
# nothing on the way leaves an extension error behind. It stays true as the
# modules land: the bare command opens tuicr itself.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

scenario_init smoke
scenario_fixture
scenario_start

# A broken import or a shortcut conflict shows here, before any command runs.
scenario_assert_lacks '\[Extension issues\]'

scenario_type '/rv'
scenario_keys Enter
scenario_wait 'Unstaged changes|Files ·' 30

# Back to the composer, so the next scenario starts from pi's prompt.
scenario_type ':q'
scenario_keys Enter
scenario_wait 'escape interrupt|commands ·' 20
scenario_pass
