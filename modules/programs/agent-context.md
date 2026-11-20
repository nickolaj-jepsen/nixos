# Working preferences

Repository-local instructions and existing conventions take precedence over these defaults.

## Documentation

Write docs when a reader has something to learn, do or look up. An overview can pair a map with a worked example. A how-to follows the reader's steps. Keep lookup details in reference. Use the plain skill when drafting. Leave out facts readers already know, can readily discover where they work, or would need only for a different task. A feature can be complete without a docs change.

Keep the local terms and formats that help readers find or use the answer. A reference table can keep its columns even when a new entry needs only a few words. If nearby prose is hard to follow, write the new passage plainly. Give separate ideas their own sentences, drop labels that repeat the text, and keep examples together so readers can use them.

When a passage becomes stale, consider deleting it. Delete the page if nothing useful remains. For compatibility decisions, check actual callers and promises the project has made.

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
- A worktree stays open when the session ends. When done, from the primary checkout, never inside it: `wt land <name>` to land it, `wt close <name>` to keep the branch, `wt drop <name>` to throw it away. To leave early: `exit_worktree` in pi, `ExitWorktree` with `remove` and `discard_changes: true` in Claude Code (safe: it runs `wt close`).
