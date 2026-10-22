# Working preferences

Repository-local instructions and existing conventions take precedence over these defaults.

## Environment

- This machine runs NixOS. Persistent system or user configuration belongs in `~/nixos`; do not use `apt`, global npm/pip installs, or edit `/etc`.
- For one-off tools, use `nix run nixpkgs#<tool>` or `nix shell nixpkgs#<tool>`.

## Tooling

- Prefer uv for Python and pnpm for Node, but defer to whatever the repo already uses.
- Prefer rebase over merge — even when asked to "merge" — unless a merge over rebase is explicitly requested.
- Never discard uncommitted work or force-push without approval.
- Prefer `gh` for GitHub operations (PRs, issues, API).
- Git worktrees live in `~/worktrees/<repo>/<name>`, created with `wt create <name>`
  (it prints the path); `git worktree add` anywhere else is blocked. `wt` also
  lists, diffs, lands and cleans them.
- In Digital-Udvikling repositories, use `ds` when it supports the operation; check `ds --help` when uncertain.

## Code style

- Comment only non-obvious intent, constraints, gotchas, or tradeoffs. Keep comments to one line when possible.
- Docstrings define the symbol's behavior, parameters, return value, errors, and invariants. Do not restate the signature or describe callers; guidance on when to call it is fine.

## Avoiding churn

Don't write anything that must be edited when unrelated code changes:

- Point to a source of truth by name (symbol, file, command), never by line number or position; don't describe callers, and don't copy lists, counts, or tours of things defined elsewhere into comments or docs.
- Tests assert observable outcomes through public interfaces: no asserting calls on in-repo mocks, no tests that echo their own mock, no broad snapshots, no assertions on copy text or styling unless that is the requirement.
- Reuse the existing definition or registry instead of adding another hand-synced copy, but don't abstract two copies that may diverge.
- When a test fails after your change, fix the code or the behaviour, not the assertion, unless the behaviour change was intended.
