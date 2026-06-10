---
name: prune-comments
description: Prune redundant or over-long comments, docstrings, and prose docs down to the minimal load-bearing why. Run after generating code to clean up comment/doc bloat. Optional scope arg — diff (default), touched, branch, repo, or a path.
argument-hint: "[diff|touched|branch|repo|<path>]"
arguments: scope
---

Reduce comment, docstring, and documentation bloat to the minimum a reader can't cheaply recover from the code. Reduction only — never add or expand.

## Scope

`$scope` selects what's in range (default `diff` when empty):

- `diff` (default) — only comments/docstrings/doc lines added or changed in the uncommitted diff, staged and unstaged (`git diff HEAD`). Comments you didn't just touch are off-limits.
- `touched` — every comment in any file the diff touches.
- `branch` — everything changed on this branch vs the default branch.
- `repo` — the whole repository.
- a path — that file or directory only.

Gather the set with git (`git diff HEAD` for `diff`, `git diff --name-only <base>...HEAD` for `branch`). For diff/branch, edit only added/changed hunks; touched/repo/path cover whole files.

## The bar each comment must clear

Keep a comment only if it works at a different level than the code: the load-bearing _why_ (intent, a gotcha, a non-obvious tradeoff or constraint), a one-line intuition over a dense multi-line block, or precision the code doesn't state (units, bounds, invariants). Otherwise:

- Same-level restatement — narrating the line it sits on → delete. A one-line summary over a block sits higher and may stay.
- Multi-line where one line suffices → compress to that line.
- Recoverable at the cost of one lookup (a stdlib call's semantics, a flag's meaning) → drop. Compressed domain knowledge that would cost a textbook or RFC dive stays.
- Written relative to the change instead of the resulting code → delete: plan/phase/step references ("Phase 2", "per the migration plan", "plan.md step 3") and change-narration ("newly added", "replaces the old handler", "moved from X"). Git history holds the narration; the plan isn't in the tree. TODOs survive only when self-contained — a concrete condition that stands without the plan ("remove after v2 migration ships"); rewrite to one if recoverable, else delete.
- Docstrings → keep the contract; cut signature restatement and "who calls this". Where the repo's linter or pervasive convention requires public-API docstrings, the floor is a one-line contract — compress to it, never delete.
- Markdown/prose → cut on density and redundancy only. Leave tone/phrasing to the avoid-ai-tropes skill; don't duplicate its job.

Measure against a reader who has only the source tree — no plan doc, no PR description, no chat transcript.

Default to one line. When a comment is genuinely load-bearing, keep it compressed rather than lose it.

## Examples

Same-level restatement — delete:

    - // increment the counter
      counter += 1

Over-long why → minimal why (real case):

    - # aarch64 emulation so this x86_64 host can cross-build the Raspberry Pi
    - # kiosk SD image (~/dev/kiosk). Some derivations run target binaries at
    - # build time (e.g. writeShellScript's bash -n), which fails without binfmt.
    + # cross-builds the Raspberry Pi kiosk SD image
      boot.binfmt.emulatedSystems = ["aarch64-linux"];

The code already says it enables aarch64 emulation — that's the _what_. The only thing unrecoverable from the code is _why this host_ has it: the cross-build. Keep that, drop the rest.

Process-relative — delete:

    - // Phase 2 of the auth migration: new token validator, replaces legacy_check
      fn validate_token(token: &str) -> Result<Claims, AuthError>

The plan isn't in the tree and git blame already says what this replaced. Nothing here survives a rewrite to "why does this code exist", so delete rather than compress.

Docstring carrying its weight — leave it:

    def settle(txn, *, retries):
        """Finalize txn; retry transient lock errors up to `retries` times.

        Raises LockError if still locked after the last retry.
        """

## Procedure

1. Resolve scope from `$scope` (default `diff` when empty); gather the target lines.
2. Enumerate every comment/docstring in scope, then rule on each: delete, compress, or keep. No comment goes unruled — a keep requires a one-line justification naming what the code can't recover. If you can't name it, it's a delete.
3. Edit the working tree in place.
4. Print the verdicts, one line per comment — `path:line  <verdict>` (e.g. `3 lines → 1`, `deleted (same-level restatement)`, `deleted (plan reference)`, `kept — lock-retry gotcha`). For `branch`/`repo`, print changes only and end with the keep count. End with `review: git diff`.

Never commit; leave edits uncommitted for review.
