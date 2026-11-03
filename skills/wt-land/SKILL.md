---
name: wt-land
description: Take finished work in a git worktree to landed commits — shape the dirty tree into a few commits, run the repo's checks, stop at a gate for review, then land locally with `wt land` or open a PR (draft, ready for review, or merged on green). Use when the user asks to land, ship, finish, merge, or open a PR for a worktree.
disable-model-invocation: true
argument-hint: "[worktree-or-branch]"
---

# wt-land

## Requirements

- Requires `wt`. The PR endings also need `gh` and an `origin` remote.
- If `wt` is missing, stop and say so: every ending lands through `wt land`.

## Spine

1. **Resolve the target.** No argument means the worktree containing cwd (`wt list --json .`); an argument names a worktree or branch (`wt list --json <target>`).
2. **Preflight** from plumbing, never from memory: `wt list --json <target>`, `git log <default>..HEAD`, and for the PR endings `gh pr view --json number,state,isDraft,url` plus `git rev-list --left-right --count <default>...origin/<default>`. Refuse and stop on the entry states below.
3. **Shape commits** (see Commits) when the tree is dirty.
4. **Fold fixups** if any subject starts with `fixup!` or `squash!`: `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash <merge-base>`.
5. **Run the repo's checks** (see Checks).
6. **Gate** (see Gate). Nothing is landed before the user answers.
7. **End** with one `wt land` (see Endings). When it names a live process in the checkout it fast-forwarded, tell the session there which paths moved (pi `send_message`, Claude `SendMessage`).
8. **Report** what landed, what was left behind, and what `wt land` said about the worktree.

## Gate

- Print the block, then ask. Use the harness's question tool when it has one (pi `ask_user_question`, Claude `AskUserQuestion`); otherwise end the turn with `Reply with one of: …`.
- Ambiguous answers ("ok", "sure") are not consent, and an earlier "just land it" does not skip the gate.

```
LAND <branch> → <default>
commits (2)
  108be2bb fix(wt): keep the worktree after landing
  5c1a2f30 feat(wt): name every verb's preconditions in --help
diff     8 files, +390 −66
checks   just fmt ✓ · just build desktop ✓ · just check ✓
base     local main 2 ahead / 0 behind origin/main
state    worktree clean · not pushed · no PR
left     4 unrelated dirty paths, not mine: modules/programs/comma.nix …
Nothing is landed until you answer.
```

- The four destinations fill the button cap: `land local · draft PR · PR for review · PR merged on green`. "Revise the commits" is free text, not a fifth button.
- When checks are red, the buttons become `fix and amend · land anyway · draft PR · stop`, and the block shows the first failing line plus the log path.
- Fixing means: fix, amend (or `git commit --fixup=<sha>` while unpushed), re-run the checks, gate again. No unattended retry loop.

## Checks

- Run whatever the repo documents in `AGENTS.md`. Here that is `just fmt` and `just build [host]` for the host that changed.
- If nothing is documented, run the test command you can see and say which one you ran.
- Checks run on the tree that will land: after commit shaping, and again after any revision.
- Report each check as the command plus its outcome; never write ✓ for "probably fine".
- Keep a red check's full log at `/tmp/wt-land/<branch>-<check>.log` and quote its first failing line.

## Commits

- One commit per coherent unit, **capped at about five**; one minimum. More than that means the task should have been split: say so instead of producing a dozen commits.
- Stage **only paths this task touched**. Anything else goes in the block as `left: N unrelated paths, not mine`. No `git add -A`.
- Subjects ≤72 characters, matched to the last ~20 subjects or `AGENTS.md`; Conventional Commits when the repo has no visible style. Body prose only when the why isn't obvious.
- Do not rewrite existing commits. The two exceptions are folding fixups and an explicit "squash this branch".
- Amend only while unpushed. After a push, a fix is a new commit; `wt` never force-pushes.
- A tip commit with the trailer `Wt-Wip: 1` is what `wt close` saved from an unfinished tree; `wt land` refuses it. Reshape it into real commits (`git reset --soft HEAD~`, then commit) before the gate.

## Endings

| Answer             | Command                                          | What happens                                         |
| ------------------ | ------------------------------------------------ | ---------------------------------------------------- |
| land local         | `wt land <name>`                                 | rebase onto local `<default>`, fast-forward it       |
| draft PR           | `wt land --draft <name> --title … --body-file …` | push and open a draft PR                             |
| PR for review      | `wt land --pr <name> --title … --body-file …`    | push and open a ready PR; the user merges on GitHub  |
| PR merged on green | `wt land --green <name> --title … --body-file …` | open it, then merge with `--rebase` once checks pass |

- Every ending closes the worktree afterwards, or leaves it for the session-exit close while this session is inside it. Don't close or delete it yourself.
- A branch never pushed is rebased onto `origin/<default>` first, so the PR holds only this task's commits. When that conflicts, `wt` says so: report the line and offer `land local`.
- `--green` returns at once when `<default>` requires checks: GitHub auto-merges. Otherwise it waits for the checks (default `--timeout 30m`); a timeout is a resume, so rerun it, in the harness's background runner (pi `bg_run`, Claude `Bash(run_in_background)`) when the wait may be long. Red checks stop it with the failing names: start the fix loop.
- A worktree holding a `gh stack` lands the whole stack: `gh stack submit`, and for `--green`, `gh stack merge` once every layer is green.
- After a merge, `wt` prints the pull line for the primary checkout when local `<default>` is behind. Report it; don't run the pull yourself.
- Never open a second PR for the same branch: `wt land --pr` finds and reuses the open one.

## Entry states

Never re-implement a refusal `wt` already makes: `wt land` is the authority on landing, and its line is reported verbatim.

- In the primary checkout: refuse. This skill lands a worktree; `/wt-land <name>` names one.
- Already landed, nothing dirty (`wt list --json` shows `landed: true`): stop with "already on `<default>`; the worktree closes when this session ends".
- Mid-rebase, merge or bisect, or a detached HEAD: stop with the exact finish-or-abort command.
- Remote ahead of the branch: stop with "`origin/<branch>` has N commits you don't have".
- History rewritten after a push: stop. `wt` never force-pushes; ask the user to push with `--force-with-lease` themselves, or open a new branch.
- PR already open: resume with requested changes first (`gh pr view <n> --comments`), then checks, then the ending again.
- PR merged: report the merge and the pull line; don't land twice.
- PR closed unmerged: stop and ask whether to reopen it or `wt drop` the branch.
- Dirty tree with none of it ours: stop with "nothing of yours to commit; N unrelated paths left behind".
- `gh` unauthenticated or no remote: offer only `land local`, with one line saying why.
- Nothing new since the last gate: legitimate; re-gate with `no new commits since the last gate`.

## PR body

- Guidance lives in HTML comments, so it never survives into review.
- Delete sections that don't apply rather than leaving `N/A`.

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

- Title: the single commit's subject, or for several a `type(scope): summary` line in the same style, ≤72 characters.
- Body: 5–15 lines for a 1–5 commit change. If it needs more, the branch should be split.
- No "Generated with", no `Co-Authored-By`, no checklists, and no account of the session's detours.
- Distill logs to the failing line instead of pasting them.
- A draft PR adds `unfinished: <what's left, which check fails>` at the top.

## Non-goals

- Don't push the default branch.
- Don't close, drop or delete the worktree: `wt land` and the session-exit close own that.
- Don't commit work you can't explain.
