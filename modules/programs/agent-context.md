# Working preferences

Repository-local instructions and existing conventions take precedence over these defaults.

## Environment

- This machine is managed by the `~/nixos` flake (NixOS, or nix-darwin on macOS). Persistent system or user configuration belongs there; do not use `apt`, global npm/pip installs, or edit `/etc`.
- For one-off tools, use `nix run nixpkgs#<tool>` or `nix shell nixpkgs#<tool>`.
- Don't create files or folders directly in `~`, or in a repo you weren't asked to change. Throwaway files (benchmarks, experiments, test fixtures) go under `/tmp` — spell the path out literally, since `$TMPDIR`, `$(mktemp -d)` and any other computed path are opaque to permission rules and make each write through one ask. Anything meant to outlive the session (plans, notes, reports) goes in `~/.local/share/agents/<topic>/`.

## Tooling

- Prefer uv for Python and pnpm for Node, but defer to whatever the repo already uses.
- Prefer rebase over merge — even when asked to "merge" — unless a merge over rebase is explicitly requested.
- Never discard uncommitted work or force-push without approval.
- Prefer `gh` for GitHub operations (PRs, issues, API).
- Git worktrees live in `~/worktrees/<repo>/<name>`, created with `wt create <name>`
  (it prints the path); `git worktree add` anywhere else is blocked. `wt` lists,
  reviews, syncs, lands, sweeps (`wt clean`), and removes them; `wt remove --force`
  archives the work in `wt trash`, and `wt restore` brings it back.
- In Digital-Udvikling repositories, use `ds` when it supports the operation; check `ds --help` when uncertain.
- A wrapper (`env CMD`, `xargs`, `nohup`, `sh -c`, `eval`, `sudo`, `find -exec`) hides the command it runs, so it asks for approval even when that command is harmless. Set variables as `VAR=x cmd`, not `env VAR=x cmd`. `timeout` and `time` pass through only when the command after them is spelled literally (`timeout 180 ./result/bin/pi`, not `timeout 180 $builtpi`).

## Code style

- Comment only non-obvious intent, constraints, gotchas, or tradeoffs. Keep comments to one line when possible.
- Docstrings define the symbol's behavior, parameters, return value, errors, and invariants. Do not restate the signature or describe callers; guidance on when to call it is fine.

## Avoiding churn

Don't write anything that must be edited when unrelated code changes:

- Point to a source of truth by name (symbol, file, command), never by line number or position; don't describe callers, and don't copy lists, counts, or tours of things defined elsewhere into comments or docs.
- Tests assert observable outcomes through public interfaces: no asserting calls on in-repo mocks, no tests that echo their own mock, no broad snapshots, no assertions on copy text or styling unless that is the requirement.
- Reuse the existing definition or registry instead of adding another hand-synced copy, but don't abstract two copies that may diverge.
- When a test fails after your change, fix the code or the behaviour, not the assertion, unless the behaviour change was intended.
