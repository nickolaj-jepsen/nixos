---
name: land
description: Take finished work to landed commits — shape the dirty tree into a few commits, run the repo's checks, stop at a gate for review, then land with `wt land`, locally or as a PR (draft, ready for review, or merged on green). An ending named in the request (`local`, `pr`, `pr on green`, …) is used without asking. Works from a worktree, from a branch checked out in the primary checkout, and from the primary checkout's default branch, where landing means pushing it. Use when the user asks to land, ship, finish, push, merge, or open a PR.
disable-model-invocation: true
argument-hint: "[local|push|pr|draft|pr on green] [worktree-or-branch]"
---

# land

## Requirements

- Requires `wt`. The PR endings and `push main` also need `gh` and an `origin` remote.
- If `wt` is missing, stop and say so: every ending lands through `wt land`.

## Modes

The mode comes from where the work is checked out, never from memory.

| Mode        | When                                                       | Local ending                                                                          |
| ----------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| worktree    | cwd or the argument is a worktree (`wt list --json <t>`)   | `land local`: rebase onto `<default>`, close the folder                               |
| root branch | the primary checkout is on a branch other than `<default>` | `land local`: rebase, then the root switches to `<default>` and the branch is deleted |
| root main   | the primary checkout is on `<default>`                     | `push main`: fast-forward `origin/<default>`                                          |

- No argument means the checkout holding cwd. An argument names a worktree, or the branch checked out in the primary checkout.
- `<default>` is `wt`'s: the branch `origin/HEAD` names, else `main`, else `master`.

## Ending from the request

The request (the words after `/land`, or what the user asked for) can name the ending; the rest of it names the target.

| Words                                                   | Ending                                                     |
| ------------------------------------------------------- | ---------------------------------------------------------- |
| `local`, `merge`                                        | land local (root main has nothing to land locally: say so) |
| `push`                                                  | push main, from root main only                             |
| `pr`                                                    | PR for review: opens it, never merges                      |
| `draft`                                                 | draft PR                                                   |
| `pr on green`, `green`, `automerge`, "merge when green" | PR merged on green                                         |

- Only an explicit ask merges a PR: `pr` alone opens one and stops.
- A named ending skips the gate's question: print the block and land. It still stops at the gate when checks are red, when commits not from this task would land, or when root main needs `rebase and push main`.
- "Land it" with no ending named asks at the gate.

## Spine

1. **Resolve the target and its mode** (see Modes).
2. **Preflight** from plumbing: `wt list --json <target>` for a worktree, `git branch --show-current` for the root, `git log <default>..HEAD` (root main: `git fetch origin <default>` then `git log origin/<default>..<default>` and `git rev-list --left-right --count <default>...origin/<default>`), and for the PR endings `gh pr view --json number,state,isDraft,url`. Refuse and stop on the entry states below.
3. **Shape commits** (see Commits) when the tree is dirty. In root main they go straight onto `<default>`.
4. **Fold fixups** if any subject starts with `fixup!` or `squash!`: `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash <merge-base>`. In root main only over unpushed commits.
5. **Run the repo's checks** (see Checks).
6. **Gate** (see Gate), unless the request named the ending (see Ending from the request). Otherwise nothing is landed before the user answers.
7. **End** with one `wt land` (see Endings). Whenever it names a live process in a checkout it moved (a fast-forward, a rebase, or the root switching branch), tell the session there what changed (pi `send_message`, Claude `SendMessage`).
8. **Report** what landed, what was left behind, and what `wt land` said about the worktree or the root's branch.

## Gate

- Print the block, then ask. Use the harness's question tool when it has one (pi `ask_user_question`, Claude `AskUserQuestion`); otherwise end the turn with `Reply with one of: …`.
- Ambiguous answers ("ok", "sure") are not consent, and an earlier "just land it" names no ending, so it does not skip the gate.

```
LAND <branch> → <default>
commits (2)
  108be2bb fix(statusline): keep the branch name beside a worktree path
  5c1a2f30 feat(land): name every ending's commands
diff     8 files, +390 −66
checks   just fmt ✓ · just build desktop ✓ · just check ✓
base     local main 2 ahead / 0 behind origin/main
state    worktree clean · not pushed · no PR
left     4 unrelated dirty paths, not mine: modules/programs/comma.nix …
Nothing is landed until you answer.
```

- Root main heads the block `LAND main → origin/main` and lists every commit in `origin/<default>..<default>`. Commits this session didn't make are marked `(not from this task)`, and the count says how many: `commits (3, 1 not from this task)`. They land too; to land without them, the user stops here.
- The four destinations fill the button cap:
  - worktree and root branch: `land local · draft PR · PR for review · PR merged on green`
  - root main: `push main · draft PR · PR for review · PR merged on green`, with `rebase and push main` in place of `push main` while `origin/<default>` is ahead
- "Revise the commits" is free text, not a fifth button.
- When checks are red, the buttons become `fix and amend · land anyway · draft PR · stop`, and the block shows the first failing line plus the log path.
- Fixing means: fix, amend (or `git commit --fixup=<sha>` while unpushed), re-run the checks, gate again. No unattended retry loop.

## Checks

- Run whatever the repo documents in `AGENTS.md`. Here that is `just fmt` and `just build [host]` for the host that changed.
- If nothing is documented, run the test command you can see and say which one you ran.
- Checks run on the tree that will land: after commit shaping, and again after any revision.
- Report each check as the command plus its outcome; never write ✓ for "probably fine".
- Keep a red check's full log at `/tmp/land/<branch>-<check>.log` and quote its first failing line.

## Commits

- **Split by concern, not by file:** a refactor, the feature built on it, an unrelated fix, and formatting or generated churn each get their own commit, ordered so each builds on the last. **Capped at about five**; one minimum. More than that means the task should have been split: say so instead of producing a dozen commits.
- Stage **only paths this task touched**. Anything else goes in the block as `left: N unrelated paths, not mine`. No `git add -A`. This matters most in the primary checkout, which other sessions share.
- **Style:** the repo's first (`AGENTS.md`, `CONTRIBUTING.md`, a commitlint config, the last ~20 subjects), else Conventional Commits (`type(scope): summary`). Imperative subject ≤72 characters; a body only for a why the diff doesn't show.
- Leave out secrets, debug output and scratch files.
- Do not rewrite existing commits. The two exceptions are folding fixups and an explicit "squash this branch".
- Amend only while unpushed. After a push, a fix is a new commit; `wt` never force-pushes.
- A tip commit with the trailer `Wt-Wip: 1` is what `wt close` saved from an unfinished tree; `wt land` refuses it. Reshape it into real commits (`git reset --soft HEAD~`, then commit) before the gate.

## Endings

| Answer               | Command                                            | What happens                                                        |
| -------------------- | -------------------------------------------------- | ------------------------------------------------------------------- |
| land local           | `wt land <target>`                                 | rebase onto local `<default>`, fast-forward it                      |
| push main            | `wt land`                                          | push `<default>` to origin, fast-forward only                       |
| rebase and push main | `wt land --rebase`                                 | rebase `<default>` onto `origin/<default>` (autostashed), then push |
| draft PR             | `wt land --draft <target> --title … --body-file …` | push and open a draft PR                                            |
| PR for review        | `wt land --pr <target> --title … --body-file …`    | push and open a ready PR; the user merges on GitHub                 |
| PR merged on green   | `wt land --green <target> --title … --body-file …` | open it, then merge with `--rebase` once checks pass                |

- In root main, the PR endings add `--branch <type>/<slug>`, named from the title (`feat/zed-open-paths`). `wt` moves the unpushed commits onto that new branch, switches the root to it at the same commit (no file moves), resets local `<default>` to `origin/<default>`, then lands it as a root branch.
- A worktree closes after every ending, or is left for the session-exit close while this session is inside it. Don't close or delete it yourself.
- A root branch:
  - `land local` leaves the root on `<default>` with the branch deleted.
  - Through a PR, the root stays on the branch until the PR merges. Once `--green` sees the merge, `wt` switches the root to `<default>`, fast-forwards it to origin's and deletes the branch. When GitHub auto-merges later, rerunning `wt land --green` does that cleanup.
- A branch never pushed is rebased onto `origin/<default>` first, so the PR holds only this task's commits. When that conflicts, `wt` says so: report the line and offer `land local`.
- `--green` returns at once when `<default>` requires checks: GitHub auto-merges. Otherwise it waits for the checks (default `--timeout 30m`); a timeout is a resume, so rerun it, in the harness's background runner (pi `bg_run`, Claude `Bash(run_in_background)`) when the wait may be long. Red checks stop it with the failing names: start the fix loop.
- A worktree holding a `gh stack` lands the whole stack: `gh stack submit`, and for `--green`, `gh stack merge` once every layer is green.
- After a worktree's merge, `wt` prints the pull line for the primary checkout when local `<default>` is behind. Report it; don't run the pull yourself.
- Never open a second PR for the same branch: `wt land --pr` finds and reuses the open one.

## Entry states

Never re-implement a refusal `wt` already makes: `wt land` is the authority on landing, and its line is reported verbatim.

- Already landed, nothing dirty: a worktree (`wt list --json` shows `landed: true`) stops with "already on `<default>`; the worktree closes when this session ends"; root main with nothing ahead of `origin/<default>` stops with "nothing to push".
- Mid-rebase, merge or bisect, or a detached HEAD: stop with the exact finish-or-abort command. A rebase `wt land` paused resumes with `wt land --continue` (or `--abort`), from the root without a target.
- Root branch while `<default>` is checked out in a worktree, or the root holding a `gh stack`: `wt` refuses. Report it and offer the PR endings, or landing from a worktree.
- A branch checked out nowhere: `wt` refuses; it needs a worktree (`wt new <branch>`) or the root.
- Root main behind `origin/<default>`: `wt land` refuses without `--rebase`. Show it in the gate's `base` line and offer `rebase and push main`; never pass `--rebase` without that answer.
- Remote ahead of the branch: stop with "`origin/<branch>` has N commits you don't have".
- History rewritten after a push: stop. `wt` never force-pushes; ask the user to push with `--force-with-lease` themselves, or open a new branch.
- PR already open: resume with requested changes first (`gh pr view <n> --comments`), then checks, then the ending again.
- PR merged: report the merge and the pull line; don't land twice. A root branch whose PR merged reruns `wt land --green` for the switch back.
- PR closed unmerged: stop and ask whether to reopen it or drop the branch (`wt drop` for a worktree).
- Dirty tree with none of it ours: stop with "nothing of yours to commit; N unrelated paths left behind".
- `gh` unauthenticated or no remote: offer only `land local` (worktree, root branch) with one line saying why; in root main there is nothing to offer, so stop.
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

- Don't push the default branch yourself: only `wt land` in root main does, after the gate.
- Don't close, drop or delete the worktree or the root's branch: `wt land` and the session-exit close own that.
- Don't commit work you can't explain.
