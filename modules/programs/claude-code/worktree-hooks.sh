#!/usr/bin/env bash
# Claude Code's WorktreeCreate, WorktreeRemove and SessionEnd hooks, backed by `wt`:
# EnterWorktree, `claude -w` and agent isolation create through `wt new`, so their
# worktrees share the shared root. Removing one, or ending a session inside one,
# runs `wt close --when-free`, which commits what is uncommitted onto the branch and
# removes the folder once Claude and its children have left it.
set -euo pipefail

input=$(cat)
command -v wt >/dev/null 2>&1 || exit 0
case "$(jq -r '.hook_event_name // empty' <<<"$input")" in
WorktreeRemove)
  path=$(jq -r '.worktree_path // empty' <<<"$input")
  [ -d "$path" ] || exit 0
  exec wt close --when-free "$path"
  ;;
SessionEnd)
  # /clear ends a conversation, not the process: the session goes on in the same folder.
  [ "$(jq -r '.reason // empty' <<<"$input")" != clear ] || exit 0
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  [ -d "$cwd" ] || exit 0
  # Only a worktree wt knows; the primary checkout and plain directories are left alone.
  (cd "$cwd" && wt list --json . >/dev/null 2>&1) || exit 0
  wt close --when-free "$cwd" 2>/dev/null || true
  ;;
*)
  cd "$(jq -r '.cwd // empty' <<<"$input")"
  exec wt new "$(jq -r '.name // empty' <<<"$input")"
  ;;
esac
