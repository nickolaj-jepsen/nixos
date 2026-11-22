# Working preferences

Use the repository’s instructions and tools first. These are defaults.

## Documentation and memory

- Ask me before writing a decision from a conversation (a grilling or planning answer, feedback, a lesson) into anything that outlasts the task: repo docs, agent instructions, a skill or memory. My answers are often for the task at hand, and once written down they read as standing rules. Documenting what a change does needs no asking.
- Treat a decision already recorded in a repo's docs as what was decided at the time, not as settled: an agent may have written it without my review. When one looks wrong or blocks a better approach, raise it with me instead of following it or working around it silently.

## Environment and files

- Manage persistent system and user configuration in `~/nixos` (NixOS, home-manager or nix-darwin), not through `apt`, global npm/pip installs or edits to `/etc`. For a one-off tool, use `nix run nixpkgs#<tool>` or `nix shell nixpkgs#<tool>`.
- Put throwaway work in your scratchpad or a directory from `mktemp -d`. Other sessions share `$TMPDIR` and may share `.agents/tmp`; don’t use fixed names directly in either. Leave disposable files there.
- Write persistent agent files and notes through `.agents/store`, the project store shared by all checkouts, not directly in `~`. Use `agent-notes root --ensure` to create the store or repair its links.

## Tool preferences

- Python: `uv`, `ruff`, `pyrefly`, `pytest`.
- JavaScript: TypeScript, Node, `pnpm`, `oxlint`, `oxfmt`, `vitest`.
- Version control: `git`, `gh` for GitHub, `gh stack` for stacked PRs, `wt` for worktrees.
- Environments: Nix flakes; `ds` for devenv in Digital-Udvikling repos.

## Git and worktrees

- A one-commit change can go on the current branch, including main. For larger changes, or when another agent is editing related files, use a separate worktree and branch (harness worktree tool, else `wt new`).
- Leave others’ changes untouched. Stage only your own paths, never `-A`.
- Commit as you go in logical steps. Rebase rather than merging.
- Push or open a PR only when asked.
- Stay in your worktree for testing and follow-ups.
