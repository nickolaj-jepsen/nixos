---
name: prune-comments
description: Prune redundant or over-long comments, docstrings, and prose docs down to the minimal load-bearing why. Run after generating code to clean up comment/doc bloat. Optional scope arg — diff (default), touched, branch, repo, or a path.
---

Reduce comment, docstring, and documentation bloat to the minimal _why_ a reader can't recover from the code. Reduction only — never add or expand.

## Scope

The argument selects what's in range (default `diff`):

- `diff` (default) — only comments/docstrings/doc lines added or changed in the uncommitted working-tree diff. Comments you didn't just touch are off-limits.
- `touched` — every comment in any file the diff touches.
- `branch` — everything changed on this branch vs the default branch.
- `repo` — the whole repository.
- a path — that file or directory only.

Gather the set with git (`git diff` for `diff`, `git diff --name-only <base>...HEAD` for `branch`). For diff/touched/branch, edit only added/changed hunks unless the scope says otherwise.

## The bar each comment must clear

Keep a comment only if it carries what a competent reader can't get from the code itself — the load-bearing _why_ (intent, a gotcha, a non-obvious tradeoff or constraint). Otherwise:

- Restates what the code plainly does → delete.
- Multi-line where one line of why suffices → compress to that line.
- Mechanics recoverable by reading the code or standard docs → drop.
- Docstrings → keep the contract; cut signature restatement and "who calls this".
- Markdown/prose → cut on density and redundancy only. Leave tone/phrasing to the avoid-ai-tropes skill; don't duplicate its job.

Default to one line. When a _why_ is genuinely load-bearing, keep it compressed rather than lose it.

## Examples

Restating the code — delete:

    - // increment the counter
      counter += 1

Over-long why → minimal why (real case):

    - # aarch64 emulation so this x86_64 host can cross-build the Raspberry Pi
    - # kiosk SD image (~/dev/kiosk). Some derivations run target binaries at
    - # build time (e.g. writeShellScript's bash -n), which fails without binfmt.
    + # cross-builds the Raspberry Pi kiosk SD image
      boot.binfmt.emulatedSystems = ["aarch64-linux"];

The code already says it enables aarch64 emulation — that's the _what_. The only thing unrecoverable from the code is _why this host_ has it: the cross-build. Keep that, drop the rest.

Docstring carrying its weight — leave it:

    def settle(txn, *, retries):
        """Finalize txn; retry transient lock errors up to `retries` times.

        Raises LockError if still locked after the last retry.
        """

## Procedure

1. Resolve scope from the argument (default `diff`); gather the target lines.
2. For each: delete, compress, or leave, per the bar above.
3. Edit the working tree in place.
4. Print a one-line-per-change summary — `path:line  <before> → <after>` (e.g. `3 lines → 1`, `deleted (restated code)`, `docstring trimmed`) — ending with `review: git diff`.

Never commit; leave edits uncommitted for review.
