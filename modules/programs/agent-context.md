# Working preferences

Explicit repository instructions take precedence over these defaults.

## Documentation

Update the docs a reader uses when a change affects what they need to know or do. Check actual callers and published promises before assuming compatibility requirements.

Keep feedback, planning answers and lessons from this session in this session. Only carry one into memory, agent instructions or a skill if I explicitly ask you to remember or apply it beyond this task.

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
- Stay in the worktree after finishing a task so the user can test and request follow-ups. Only leave if asked, using `exit_worktree` in pi or `ExitWorktree` in Claude Code with `action: "keep"`. To land, close or drop it when asked, leave with `keep` first. From the primary checkout, run `wt land <name>` to land it, `wt close <name>` to remove the checkout but keep its work, or `wt drop <name>` to throw it away.
