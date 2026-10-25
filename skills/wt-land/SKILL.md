---
name: wt-land
description: Take finished work in a git worktree to landed commits — shape the dirty tree into a few commits, run the repo's checks, stop at a gate for review, then land locally with `wt apply` or open a PR (draft, awaiting your review, or CI automerge). Use when the user asks to land, ship, finish, merge, or open a PR for the current branch or worktree.
disable-model-invocation: true
argument-hint: "[worktree-or-branch]"
arguments: target
---

# wt-land

Requires `wt`, `gh` and `python3`. If `wt` is missing, stop and say so: every ending lands through `wt`.

Local landing is `wt apply`; `pr.py` only reads remote state, opens/watches/merges PRs. Never wrap one in the other, and never hand-write `gh pr merge` — the script re-checks state before merging so the flags can't drift.

```bash
PR="python3 <skill-dir>/scripts/pr.py"   # substitute the absolute path of this skill directory
$PR status --json                        # everything the gate needs, in one call
```

## Spine

1. **Resolve the target.** No argument means the worktree containing cwd: `git rev-parse --show-toplevel`, then match against `wt status` (JSON, all worktrees of this repository, or one with `wt status <target>`). An argument names a worktree or branch.
2. **Preflight** from plumbing, never from memory: `wt status <target>`, `wt list`, `git log`, `$PR status --json`. Refuse-and-stop on the entry states below.
3. **Shape commits** (see Commits) when the tree is dirty.
4. **Fold fixups** if any subject starts with `fixup!` or `squash!`: `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash <merge-base>`.
5. **Run the repo's checks** (see Checks).
6. **Gate** (see Gate). Nothing is landed before the user answers.
7. **End.** `local`: `wt apply <name>` from the worktree, then rebuild the landed tree. PR endings: `$PR open`, `$PR watch`, `$PR merge`.
8. **Report** what landed, what was left behind, and the cleanup line.

## Gate

Print the block, then ask. Use the harness's question tool when it has one (pi `ask_user_question`, Claude `AskUserQuestion`); otherwise end the turn with `Reply with one of: …`. Ambiguous answers ("ok", "sure") are not consent, and an earlier "just land it" does not skip the gate.

```
LAND <branch> → <default>
commits (2)
  108be2bb feat(wt): let apply land a worktree without deleting it
  5c1a2f30 feat(wt): name every verb's preconditions in --help
diff     8 files, +390 −66
checks   just fmt ✓ · just build desktop ✓ · wt tests 32/32 ✓
base     local main 2 ahead / 0 behind origin/main (fetched 4m ago)
state    worktree clean · not pushed · no PR
left     4 unrelated dirty paths, not mine: modules/programs/comma.nix …
Nothing is landed until you answer.
```

Four destinations, which is exactly the button cap: `land local · draft PR · PR for review · PR + automerge`. "Revise the commits" is free text, not a fifth button.

When checks are red the buttons become `fix and amend · land anyway · draft PR · stop`, and the block shows the first failing line plus the log path. Fixing means: fix, amend (or `git commit --fixup=<sha>` while unpushed), re-run the checks, gate again. No unattended retry loop.

## Checks

Whatever the repo documents in `AGENTS.md`. Here that is `just fmt` and `just build [host]` for the host that changed. If nothing is documented, run the test command you can see and say which one you ran. Checks run on the tree that will land, so they come after commit shaping and re-run after any revision.

Report each check as the command plus its outcome; never write ✓ for "probably fine". Keep a red check's full log at `/tmp/wt-land/<branch>-<check>.log` and quote its first failing line.

## Commits

- One commit per coherent unit, **capped at about five**; one minimum. More than that means the task should have been split — say so instead of producing a dozen commits.
- Stage **only paths this task touched**. Anything else goes in the block as `left: N unrelated paths, not mine`. No `git add -A`.
- Subjects ≤72 characters, matched to the last ~20 subjects or `AGENTS.md`; Conventional Commits when the repo has no visible style. Body prose only when the why isn't obvious.
- Do not rewrite existing commits. Two exceptions: folding fixups, and an explicit "squash this branch". Amend only while unpushed; after a push, a fix is a new commit unless the user approves `--force-with-lease`.

## Base and remote

`local` lands onto the local default branch. PR endings are re-parented so the PR contains only this task's commits:

```bash
git rebase --onto origin/<default> <default> <branch>
```

Repo divergence is reported, never acted on: no `pull`, no `reset`, no push of the default branch. If the re-parent conflicts, the branch depends on unpushed default-branch commits — stop and say the two ways out are pushing `<default>` or landing locally.

## PR endings

| ending         | commands                                                                                              |
| -------------- | ----------------------------------------------------------------------------------------------------- |
| draft PR       | `$PR open --draft --title … --body-file …`, report the URL, stop                                      |
| PR for review  | `$PR open --ready …`, `$PR watch` (waits for approval), then `$PR merge`                              |
| PR + automerge | `$PR open --ready …`, `$PR watch --no-require-review` (CI only), then `$PR merge --no-require-review` |

`watch` prints one line per transition and exits `10` approved+green, `11` changes requested, `12` checks failed, `3` conflicting with the base, `13` closed/merged elsewhere, `14` timeout, `1` still waiting. Anything other than `1` ends the wait; `1` from `--once` means "not yet". It is resumable: re-running re-reads state, so a killed turn or a sleeping laptop costs nothing. Long waits belong in the harness's background runner (pi `bg_run`, Claude `Bash(run_in_background)`); otherwise run `watch --timeout 5m` in the foreground and re-invoke.

`11` means the fix loop: read the review comments (`gh pr view <n> --comments`), fix in the worktree, push, `watch` again. Never open a second PR for the same branch.

Merging is `gh pr merge --rebase`. Post-merge, report `origin/<default>`'s new sha and the local-behind line with the primary checkout's path — do not run the pull yourself.

## Entry states

Never re-implement a refusal `wt` already makes: `wt apply` is the authority on landing, and its line is reported verbatim.

| state                                                                  | behaviour                                                                                |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| in the primary checkout on the default branch                          | refuse; `wt-land <name>` targets a worktree. Never commit on the default branch.         |
| already landed, nothing dirty (`wt status` → `ahead 0`, `landed true`) | stop: "already on `<default>` as `<sha>`; `wt clean` removes it once this session exits" |
| mid-rebase/merge/bisect, or detached HEAD                              | stop with the exact finish-or-abort command                                              |
| remote ahead of the branch                                             | stop: "`origin/<branch>` has N commits you don't have"                                   |
| history rewritten after a push                                         | ask explicitly about `--force-with-lease`; never silently force                          |
| PR already open                                                        | resume: requested changes first, then checks, then merge                                 |
| PR merged                                                              | report the merge commit and the pull line; don't merge twice                             |
| PR closed unmerged                                                     | stop and ask whether to reopen or drop the branch                                        |
| dirty tree with none of it ours                                        | stop: "nothing of yours to commit; N unrelated paths left behind"                        |
| `gh` unauthenticated or no remote                                      | offer only `local`, with one line saying why                                             |
| nothing new since the last gate                                        | legitimate: re-gate with `no new commits since the last gate`                            |

## PR body

Guidance lives in HTML comments so it never survives into review. Delete sections that don't apply rather than leaving `N/A`.

```markdown
<!-- Why: the symptom or missing capability today, and the outcome wanted. Not the diff. -->

## Why

<!-- One line per commit or subsystem. -->

## What

<!-- Commands actually run, with their output. "CI passes" is not a result. -->

## Verify

<!-- Only if it can bite later: excluded commits, stale base, migration, restart. Delete otherwise. -->

## Notes
```

Title: the single commit's subject, or for several a `type(scope): summary` line in the same style, ≤72 characters. 5–15 lines of body for a 1–5 commit change; if it needs more, the branch should be split. No "Generated with", no `Co-Authored-By`, no checklists, no account of the session's detours, and logs distilled to the failing line instead of pasted. A draft PR adds `unfinished: <what's left, which check fails>` at the top.

## Non-goals

Don't touch the primary checkout's HEAD, don't push the default branch, don't delete the worktree (that's `wt clean`, once the session has left it), and don't commit work you can't explain.
