#!/usr/bin/env bash
# Claude Code's WorktreeCreate hook, backed by `wt`: EnterWorktree, `claude -w`
# and agent isolation create through `wt create`, so their worktrees share the
# shared root. Removal is Claude Code's own: when the path is a git worktree it
# falls back to `git worktree remove --force`, which leaves the branch behind.
set -euo pipefail

command -v wt >/dev/null 2>&1 || exit 0
input=$(cat)
cd "$(jq -r '.cwd // empty' <<<"$input")"
exec wt create "$(jq -r '.name // empty' <<<"$input")"
