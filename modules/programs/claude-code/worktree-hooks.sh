#!/usr/bin/env bash
# Claude Code's WorktreeCreate and WorktreeRemove hooks, backed by `wt`:
# EnterWorktree, `claude -w` and agent isolation create through `wt new`, so their
# worktrees share the shared root. An explicit removal (ExitWorktree with remove)
# runs `wt close`, which commits what is uncommitted onto the branch and removes the
# folder. Nothing closes a worktree when a session or subagent ends; `wt clean`
# does that by hand.
set -euo pipefail

input=$(cat)
command -v wt >/dev/null 2>&1 || exit 0
case "$(jq -r '.hook_event_name // empty' <<<"$input")" in
WorktreeRemove)
  path=$(jq -r '.worktree_path // empty' <<<"$input")
  [ -d "$path" ] || exit 0
  # wt refuses the folder it runs in, and the hook starts in the worktree.
  cd /
  exec wt close "$path"
  ;;
*)
  cd "$(jq -r '.cwd // empty' <<<"$input")"
  exec wt new "$(jq -r '.name // empty' <<<"$input")"
  ;;
esac
