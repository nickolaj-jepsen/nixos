# Working preferences

Repository-local instructions and existing conventions take precedence over these defaults.

## Environment

- This machine is managed by the `~/nixos` flake (NixOS, or nix-darwin on macOS). Persistent system or user configuration belongs there; do not use `apt`, global npm/pip installs, or edit `/etc`.
- For one-off tools, use `nix run nixpkgs#<tool>` or `nix shell nixpkgs#<tool>`.
- Put throwaway files (benchmarks, experiments, spikes, builds, test fixtures) in a directory of your own: your scratchpad, or `mktemp -d`. `$TMPDIR` and `.agents/tmp` can be shared with other sessions, so never write a fixed name straight into them. Scratch is disposable; don't copy files out of it just to keep them.
- Notes and persistent files live in the project's store, `agent-notes root`, which every checkout sees as `.agents/store`. Write notes through the link, so an editor shows them beside the code and git only ever sees a link. `agent-notes root --ensure` creates the store and repairs the links. Don't create files or folders directly in `~`.

## Tooling

Always defer to the repo's existing tooling, but if you have a choice, prefer these:

- python:
  - `uv`
  - `ruff`
  - `pyrefly`
  - `pytest`
- javascript:
  - `typescript`
  - `node`
  - `pnpm`
  - `oxlint`
  - `oxfmt`
  - `vitest`
- version control:
  - `git` for version control
  - `gh` for GitHub operations
  - `gh stack` for stacked prs
  - `wt` for worktree management (custom tool)
- other:
  - `ds` for managing the devenv in Digital-Udvikling repos (custom tool)
  - `nix` + flakes for reproducible builds and environments

## Git

- A change that fits in one commit may go straight onto the current branch (main included).
- A larger change gets its own worktree and branch (the harness tool, else `wt new`). Commit as you go there.
- Use a worktree even for a small change when another agent is working on the same or related files, so neither of you commits over the other.
- Keep commits to the logical steps of the change: a change that should be 2 commits doesn't land as 10. Fold a fix to an earlier commit into it with `git commit --fixup`.
- Never touch changes you didn't make. Stage only your own paths, never `-A`.
- Never push or open a PR unless asked.
- No merge commits: rebase. `git rebase` autosquashes the fixups.
- Whether your subagents share your checkout or get worktrees of their own is your call, and so is managing those worktrees.
- A worktree stays open when the session ends. When done, from the primary checkout, never inside it: `wt land <name>` to land it, `wt close <name>` to keep the branch, `wt drop <name>` to throw it away. To leave early: `exit_worktree` in pi, `ExitWorktree` with `remove` and `discard_changes: true` in Claude Code (safe: it runs `wt close`).
