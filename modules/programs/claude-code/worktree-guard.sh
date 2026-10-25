#!/usr/bin/env bash
# PreToolUse gate for Bash: an agent calling git directly must not scatter
# worktrees across the disk. The layout and the check live in `wt guard`
# (modules/scripts/wt.py), shared with the pi and opencode adapters; this file
# only speaks Claude Code's hook contract — exit 2 blocks the call and shows
# stderr to the model.
set -euo pipefail

cmd=$(jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0
# Cheap filter first: both jq and wt above are process spawns, this is not.
case "$cmd" in *worktree*) ;; *) exit 0 ;; esac
command -v wt >/dev/null 2>&1 || exit 0

rc=0
reason=$(wt guard "$cmd") || rc=$?
# 1 is the guard's "blocked". Anything else means it could not run — let the
# call through rather than fail every git command in the session.
[ "$rc" -eq 1 ] || exit 0

printf '%s\n' "$reason" >&2
exit 2
