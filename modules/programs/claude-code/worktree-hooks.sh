#!/usr/bin/env bash
# Claude Code's WorktreeCreate and WorktreeRemove hooks, backed by `wt`: EnterWorktree,
# `claude -w` and agent isolation create through `wt create`, so their worktrees share
# the shared root, and removal goes through `wt remove`, which deletes the branch and
# refuses dirty or unlanded work. Claude keeps the worktree when this exits non-zero.
set -euo pipefail

input=$(cat)
case "$(jq -r '.hook_event_name // empty' <<<"$input")" in
WorktreeRemove)
  path=$(jq -r '.worktree_path // empty' <<<"$input")
  [ -d "$path" ] || exit 0
  command -v wt >/dev/null 2>&1 || {
    echo "wt is not on PATH; keeping $path" >&2
    exit 1
  }
  # Out of the worktree, or wt refuses to delete the directory it runs in.
  cd /
  exec wt remove "$path"
  ;;
*)
  command -v wt >/dev/null 2>&1 || exit 0
  cd "$(jq -r '.cwd // empty' <<<"$input")"
  exec wt create "$(jq -r '.name // empty' <<<"$input")"
  ;;
esac
