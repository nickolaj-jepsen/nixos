---
name: land
description: Take finished work to landed commits — shape the dirty tree into a few commits, run the repo's checks, stop at a gate for review, then land it locally (worktrunk's `wt merge` from a worktree, plain git from the primary checkout), push the default branch, or open a PR (draft, ready for review, or merged on green) with `gh`. Works from a worktree, from a branch checked out in the primary checkout, and from the primary checkout's default branch, where landing means pushing it. An ending named in the request (`local`, `pr`, `pr on green`, …) is used without asking. Use when the user asks to land, ship, finish, push, merge, or open a PR.
disable-model-invocation: true
argument-hint: "[local|push|pr|draft|pr on green] [worktree-or-branch]"
---

# land

## Requirements

- Local landing from a worktree uses worktrunk (`wt`); everything else is plain `git`. The PR endings and `push main` need `gh` and an `origin` remote.
- If `wt` is missing, a worktree can still take the PR endings; say why `land local` is not offered.

## Modes

The mode comes from where the work is checked out, never from memory.

| Mode        | When                                                       | Local ending                                                                              |
| ----------- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| worktree    | cwd or the argument is a linked worktree                   | `land local`: `wt merge` rebases onto `<default>`, fast-forwards it, removes the worktree |
| root branch | the primary checkout is on a branch other than `<default>` | `land local`: rebase onto `<default>`, fast-forward it, switch to it, delete the branch   |
| root main   | the primary checkout is on `<default>`                     | `push main`: fast-forward `origin/<default>`                                              |

- No argument means the checkout holding cwd. An argument names a worktree (branch or path), or the branch checked out in the primary checkout.
- `<default>` is the branch `origin/HEAD` names, else `main`, else `master`.
- `wt list --format=json` lists the worktrees: `.branch` and `.worktree.path` locate the target, and `.display.state` is `is_main` for the primary checkout. Without `wt`: `git rev-parse --git-dir` equals `git rev-parse --git-common-dir` only in the primary checkout.

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
2. **Preflight** from plumbing: `git branch --show-current`, `git status --porcelain`, `git log <default>..HEAD` (root main: `git fetch origin <default>` then `git log origin/<default>..<default>` and `git rev-list --left-right --count <default>...origin/<default>`), and for the PR endings `gh pr view <branch> --json number,state,isDraft,url`. Refuse and stop on the entry states below.
3. **Commit** the task's uncommitted work (see Commits). In root main the commits go straight onto `<default>`.
4. **Fold fixups** if any subject starts with `fixup!` or `squash!`: `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash <merge-base>`. In root main only over unpushed commits.
5. **Run the repo's checks** (see Checks).
6. **Gate** (see Gate), unless the request named the ending (see Ending from the request). Otherwise nothing is landed before the user answers.
7. **End** with the ending's commands (see Endings). When an ending moves files in another checkout (a fast-forward of a checked-out `<default>`, a rebase, or the root switching branch) and a session works there, tell it what changed (pi `send_message`, Claude `SendMessage`).
8. **Report** what landed, what was left behind, and what became of the worktree or the root's branch.

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

Nothing lands uncommitted: commit the task's work before the checks.

- **Split by concern, not by file:** a refactor, the feature built on it, an unrelated fix, and formatting or generated churn each get their own commit, ordered so each builds on the last. **Capped at about five**; one minimum. More than that means the task should have been split: say so instead of producing a dozen commits.
- Stage **only paths this task touched**. Anything else goes in the block as `left: N unrelated paths, not mine`. No `git add -A`. This matters most in the primary checkout, which other sessions share.
- **Style:** the repo's first (`AGENTS.md`, `CONTRIBUTING.md`, a commitlint config, the last ~20 subjects), else Conventional Commits (`type(scope): summary`). Imperative subject ≤72 characters; a body only for a why the diff doesn't show.
- Leave out secrets, debug output and scratch files.
- Do not rewrite existing commits. The two exceptions are folding fixups and an explicit "squash this branch".
- Amend only while unpushed. After a push, a fix is a new commit; never force-push.

## Endings

### Local

- **land local, worktree:** `wt -C <worktree-path> merge --no-commit` (or `wt merge --no-commit` from inside it). `wt merge` merges the worktree it runs in; it takes no source branch. It rebases onto local `<default>`, fast-forwards it, keeps the commits as they are (`--no-commit` implies no squash, and refuses a dirty worktree instead of committing it), then removes the worktree and its branch in the background. When this session works inside the worktree, add `--no-remove` and tell the user `wt remove <branch>` cleans it up.
- When the primary checkout has `<default>` checked out, its files move along with the fast-forward, and its uncommitted changes stay where they are.
- A rebase conflict stops `wt merge` with the rebase open in the worktree: report the conflicting paths. Once they are resolved and staged, `git -C <worktree-path> rebase --continue`, then the same `wt merge` again; `git -C <worktree-path> rebase --abort` puts the branch back.
- **land local, root branch**, plain git in the primary checkout:
  1. `git rebase --autostash <default>`; on a conflict, report it, then `--continue` once resolved or `--abort`.
  2. `git switch <default>`. Refused when `<default>` is checked out in a linked worktree: report git's line and offer the PR endings.
  3. `git merge --ff-only <branch>`
  4. `git branch -d <branch>`

### Push main (root main)

- **push main:** `git push origin <default>`. A plain push is fast-forward only; refused means `origin/<default>` moved: offer `rebase and push main`.
- **rebase and push main:** `git pull --rebase --autostash origin <default>`, then `git push origin <default>`. Never without that answer at the gate.

### Pull requests

- **Reuse first:** `gh pr view <branch> --json number,state,url`; an open PR is pushed to, never duplicated.
- **Base:** a branch never pushed is rebased onto `origin/<default>` first (`git fetch origin <default>` then `git rebase origin/<default>`), so the PR holds only this task's commits. On a conflict, abort, report the line and offer `land local`. A pushed branch is only pushed on, never forced.
- **Push and open:** `git push -u origin <branch>`, then `gh pr create --base <default> --head <branch> --title … --body-file …` plus `--draft` for a draft PR.
- **Merged on green:** after opening it, `gh pr merge <n> --rebase --auto`. When auto-merge is refused (the repo doesn't allow it or requires no checks), wait with `gh pr checks <n> --watch --fail-fast` in the harness's background runner (pi `bg_run`, Claude `Bash(run_in_background)`), then `gh pr merge <n> --rebase`. Red checks: report the failing names and start the fix loop.
- **Root main to a PR:** move the unpushed commits onto a new branch named from the title (`feat/zed-open-paths`): `git switch -c <type>/<slug>`, which keeps the files where they are, then `git branch -f <default> origin/<default>`. Land it as a root branch PR.
- **Root branch after its PR merges:** `git switch <default>`, `git pull --ff-only`, `git branch -D <branch>`. `-D` because a rebase merge gives the commits new hashes, so `-d` refuses once GitHub has deleted the head branch.
- **A worktree after its PR:** it stays until the PR merges; report that `wt step prune` removes it once merged (it recognises a rebase merge), or `wt remove <branch>` before that. Don't remove it yourself.
- **A `gh stack`:** land it with the gh-stack skill: `gh stack submit`, and for green, `gh stack merge` once every layer passes.

## Entry states

- Already landed, nothing dirty: a worktree whose branch has no commits outside `<default>` (`wt list --format=json` shows `.display.state` `integrated` or `empty`) stops with "already on `<default>`; `wt remove` cleans up the worktree"; root main with nothing ahead of `origin/<default>` stops with "nothing to push".
- Mid-rebase, merge or bisect, or a detached HEAD: stop with the exact finish-or-abort command.
- A branch checked out nowhere: `wt merge` needs a worktree; offer `wt switch <branch>` to make one, or the PR endings.
- A worktree with uncommitted paths that aren't ours: `wt merge --no-commit` refuses it. Stop and list them; never commit or discard them yourself.
- The primary checkout has uncommitted changes in a path the branch changes: `wt merge` refuses with "conflicting uncommitted changes" and names the paths. Report it; the user commits or stashes them there.
- A project `pre-merge` hook (`.config/wt.toml`) not yet approved: without a terminal `wt merge` stops with "needs approval to execute" and lists the commands. Show them to the user; only on their yes, rerun with `--yes`.
- Root main behind `origin/<default>`: show it in the gate's `base` line and offer `rebase and push main`.
- Remote ahead of the branch: stop with "`origin/<branch>` has N commits you don't have".
- History rewritten after a push: stop. Never force-push; ask the user to push with `--force-with-lease` themselves, or open a new branch.
- PR already open: resume with requested changes first (`gh pr view <n> --comments`), then checks, then the ending again.
- PR merged: report the merge and the cleanup for its mode; don't land twice.
- PR closed unmerged: stop and ask whether to reopen it or drop the branch (`wt remove -D <branch>` for a worktree, `git branch -D <branch>` otherwise).
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

- Don't push the default branch except in the `push main` endings, after the gate.
- Don't remove the worktree or delete a branch beyond what the ending says.
- Don't commit work you can't explain.
