#!/usr/bin/env bash
# D11's grammar in a real pi on a fixture checkout: a bare `/rv` is tuicr's own
# view, a scope word is the argv it stands for, and anything else is passed to
# tuicr as typed. Nothing asks which scope to review any more, so the picker's
# absence is asserted too.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib.sh"

scenario_init argv
scenario_fixture
scenario_start

# A broken import or a shortcut conflict shows here, before any command runs.
scenario_assert_lacks '\[Extension issues\]'

# --- bare /rv -------------------------------------------------------------
# tuicr's own view opens directly — its local session/commit selector — and
# nothing asks which scope to review.
scenario_type '/rv'
scenario_keys Enter
scenario_wait 'Unstaged changes|Files ·' 30
scenario_assert_lacks 'Review scope'
scenario_type ':q'
scenario_keys Enter
scenario_wait 'escape interrupt|commands ·' 20
scenario_assert_lacks 'Files ·'

# --- a shortcut -----------------------------------------------------------
# `changes` is `-w`: the uncommitted change is what tuicr shows.
scenario_type '/rv changes'
scenario_keys Enter
scenario_wait 'Files · 0/1' 30
scenario_assert_has 'a\.ts'
scenario_type ':q'
scenario_keys Enter
scenario_wait 'escape interrupt|commands ·' 20

# --- tuicr argv as typed --------------------------------------------------
# A revset and a diff filter, with quotes and spaces kept as data (B2).
git -C "$SCENARIO_FIXTURE" -c user.email=review@example.invalid -c user.name=Review \
  commit -qam "committed before the revset"
scenario_type "/rv -r 'HEAD~1..HEAD' -p a.ts"
scenario_keys Enter
# One commit is the whole range, so tuicr opens on it directly (no file list).
scenario_wait 'Commit Message|a\.ts' 30
scenario_assert_has 'a\.ts'
scenario_type ':q'
scenario_keys Enter
scenario_wait 'escape interrupt|commands ·' 20

# --- a shortcut with an argument after it ---------------------------------
# `changes -p b.ts` is `-w -p b.ts`: only the dirty file it names is shown.
printf 'export function add(a: number, b: number) {\n  return a + b + 1;\n}\n' \
  >"$SCENARIO_FIXTURE/b.ts"
scenario_type '/rv changes -p b.ts'
scenario_keys Enter
# One file after `-p`, so tuicr opens on it directly.
scenario_wait 'b\.ts' 30
scenario_assert_has 'b\.ts'
scenario_type ':q'
scenario_keys Enter
scenario_wait 'escape interrupt|commands ·' 20

scenario_pass
