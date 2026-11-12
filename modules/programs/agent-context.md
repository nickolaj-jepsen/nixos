# Working preferences

Repository-local instructions and existing conventions take precedence over these defaults.

## Environment

- This machine is managed by the `~/nixos` flake (NixOS, or nix-darwin on macOS). Persistent system or user configuration belongs there; do not use `apt`, global npm/pip installs, or edit `/etc`.
- For one-off tools, use `nix run nixpkgs#<tool>` or `nix shell nixpkgs#<tool>`.
- Use $TMPDIR, $(mktemp -d) or any other computed path for throwaway files (benchmarks, experiments, spikes, builds, test fixtures), this directory is volatile and clears on reboot. Don't copy files out of it or the scratchpad just to keep them.
- Notes and persistent files live in the project's store, `agent-notes root`, which every checkout sees as `.agents/store` (its scratch is `.agents/tmp`, reaped by age). Write notes through the link, so an editor shows them beside the code and git only ever sees a link. `agent-notes root --ensure` creates the store and repairs the links. Don't create files or folders directly in `~`.

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
  - `wt` (worktrunk) for worktree management: `wt switch -c <branch>`, `wt list`, `wt merge`, `wt remove`, `wt step prune`
- other:
  - `ds` for managing the devenv in Digital-Udvikling repos (custom tool)
  - `nix` + flakes for reproducible builds and environments

- Work in the checkout you are in, on its current branch (main included). Unless your work would conflict with the user's or another agent's current work, then use a worktree (using `wt`). Make sure to clean up worktrees and branches you create.
- The worktree tools (if existent) are integrated with `wt`, so use them rather than `wt` directly: `wt switch` in a shell leaves the session where it is.
- `wt switch --create` branches off local `main`; fetch first and pass `--base` for whichever of `main` and `origin/main` is furthest along.
- A new worktree holds no gitignored files (`.env`, `node_modules`, build output). When it needs them, `wt step copy-ignored --require-include` copies the ones the primary checkout's `.worktreeinclude` lists.
- `wt remove` refuses a worktree with uncommitted changes; commit or discard them first.
- Avoid merge commits. If you need to merge, rebase instead.
- Use fixup commits to apply fixes to previous commits in a branch, rebase before merging
