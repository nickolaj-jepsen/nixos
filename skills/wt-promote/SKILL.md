---
name: wt-promote
description: Move the current worktree's branch into the repo's primary checkout (e.g. ~/nixos) for work that must run from that path, sending whatever is there to its own worktree — asking the agent working there to move first, or moving it yourself — and offering a rebase onto local or origin main when main moved. `--back` returns the branch to its worktree and the primary to main. Use when the user asks to promote, swap in, or move a branch or worktree to the main checkout or main repo path, or to hand that path back.
disable-model-invocation: true
argument-hint: "[worktree] | --back"
---

# wt-promote

Requires `wt` with the `promote` and `evict` verbs and `python3`. If either verb is missing, stop and say so.

`wt promote` and `wt evict` do every git step under wt's repo lock, refuse before changing anything, and name the stash sha of any work they could not put back. This skill does what wt can't: find the agents involved, message them, ask the user, and move the session. Never re-do a wt step by hand, and report a wt refusal verbatim.

```bash
OCC="python3 <skill-dir>/scripts/occupants.py"   # substitute the absolute path of this skill directory
$OCC list <path>       # live Claude Code / pi sessions whose cwd is inside <path>, this one excluded
$OCC wait <primary>    # one line per change; exits 0 once <primary> is on its default branch and clean
```

## Spine: `/wt-promote [worktree]`

1. **Resolve the target.** No argument means the worktree containing cwd. In the primary checkout with no argument, stop: there is nothing to promote from here; `/wt-promote <worktree>` names one.
2. **Plan**: `wt promote --dry-run --json <target>`. It fetches `origin/<default>` and reports the primary checkout (`occupant`), the source worktree and the bases. Then `$OCC list <primary>` and `$OCC list <source path>`.
3. **Decide** (see Occupant and Base). Ask everything in **one** question dialog (Claude `AskUserQuestion`, pi `ask_user_question`): the occupant question and the base question, each only when it has a real choice. With nothing to ask, print the block and go on: the user invoked this.
4. **Clear the primary** if the answer was 1a (see Asking the occupant).
5. **Leave the worktree.** Claude Code: `ExitWorktree` with `keep`, which returns the session to where it started. A session still inside the worktree makes wt keep its folder as a detached husk, and Claude Code's worktree isolation refuses git aimed at the primary from there. pi has no such move: its shell stays in the worktree, and the folder stays detached.
6. **Promote**: `wt promote --json [--onto local|origin] [--dirty …] [--name …] <branch>`, from any directory in the repo.
7. **Enter the primary** when the session isn't already there: `EnterWorktree` with `path` set to the primary checkout. If that is refused, or in pi, give the user the resume line (`cd <primary> && claude --resume`, or `pi` restarted there) and say the old folder is a detached husk until `wt clean`.
8. **Tell bystanders.** Every agent `$OCC list <primary>` showed when the primary was clean, and every other agent `$OCC list <source>` showed: one `SendMessage` (pi `send_message`) saying what now sits in `<primary>`, or that `<source>` is detached.
9. **Report** the block below with wt's `report` lines, every stash sha it kept, and the two ways on: `/wt-land` lands from the primary and puts it back on `<default>`; `/wt-promote --back` hands the branch back without landing.

```
PROMOTE wt-promote → /home/nickolaj/nixos
primary  was main · clean; nixos-5e (claude) inside, told
source   ~/worktrees/nixos/wt-promote removed, branch kept
base     rebased onto origin/main (+3)
left     stash 1a2b3c4: carried edits that did not apply; git stash apply 1a2b3c4
```

## Occupant

What `occupant` in the plan says sits in the primary checkout decides the question:

| primary holds                           | agents inside | ask                                                                           |
| --------------------------------------- | ------------- | ----------------------------------------------------------------------------- |
| `<default>`, clean                      | any           | nothing; they get the step-8 message                                          |
| `<default>` with uncommitted changes    | yes           | **1a** ask `<agent>` to move it · **2** don't make a worktree · **3** cancel  |
| `<default>` with uncommitted changes    | no            | **1b** move it to a new worktree · **2** don't make a worktree · **3** cancel |
| another branch (`evicts`), clean or not | yes           | **1a** ask `<agent>` to move it · **3** cancel                                |
| another branch (`evicts`), clean or not | no            | **1b** send it back to `<evictTo>` · **3** cancel                             |

- **1b** on `<default>`: `--dirty move --name <name>`. Propose the name from `git -C <primary> diff --stat` (kebab case, like the repo's branch names), shown in the option's description; a different name is the user's free text.
- **1b** on another branch: nothing to pass; wt sends it back to its worktree with its uncommitted changes.
- **2** opens a second question (one more dialog, not a fifth button): `carry` them into the promoted branch · `stash` them · `wip` commit on a new branch with no worktree (`--dirty wip --name <name>`). wt refuses `carry` when the branch changes the same paths; then ask again without it.
- **3** stops here; nothing has changed.

`refuses` lines in the dry-run (a merge, rebase, cherry-pick, revert or bisect in progress, or a build running from the primary) are stops, not questions: report the line, including its finish-or-abort command. `busy` processes that aren't agents (a shell, an editor, a dev server) go in the block and don't stop anything.

## Base

`bases.local.behind` and `bases.origin.behind` count the commits each base has that the branch lacks. Offer only the bases where that is above 0, plus `don't rebase`; when both are 0, skip the question. Name `bases.unpushed` in the option text when local `<default>` is ahead of origin, since rebasing onto local carries those commits into the branch. The rebase happens inside the source worktree before anything moves, so a conflict aborts it with nothing changed: report wt's line and offer to resolve the conflict in the worktree, or to promote without the rebase.

## Asking the occupant (1a)

Send this to each agent `$OCC list <primary>` returned (Claude `SendMessage`, pi `send_message`), filled in:

```
Time-sensitive: please move your work out of <primary> now, before anything else. Another session needs that checkout for <branch>.
Run `wt evict --json` from <primary>. If it refuses because of uncommitted changes on <default>, run `wt evict --json --dirty move --name <a branch name for your work>` instead.
Then move your session into the `evictedTo` path it prints (Claude Code: EnterWorktree with that path) and carry on there.
Reply when done, or say why you can't.
```

Then start `$OCC wait <primary> --timeout 900` under the harness's background runner (Claude `Monitor`, pi `bg_run`) and wait. If the user says to wait longer or stop waiting, re-arm the wait with the new timeout or stop it. When it prints `free:`, run the dry-run again (the primary changed) and continue at step 5. If it times out, or the occupant replies that it can't move, ask the user: wait longer · 1b move it myself · cancel.

## `/wt-promote --back`

1. Must run in the primary checkout on a promoted branch (`wt list --json .` → `promoted: true`). Otherwise stop and say where the session is.
2. `wt evict --dry-run --json`, then `wt evict --json`. Report a refusal verbatim.
3. Move the session into the `evictedTo` path: `EnterWorktree` with that path (pi: the resume line).
4. If `previouslyEvicted` is set, find who works on it: `$OCC list <root>/<repo>/<previouslyEvicted>`. Tell each one: `<primary> is free again (back on <default>); run /wt-promote in your session if you want <previouslyEvicted> back there.` No agent there, no message.
5. Report what moved where.

This is the only hand-back message. Landing from the primary with `/wt-land` and a later promotion by another session don't send one.

## Non-goals

Don't commit, push, or touch `<default>`'s ref here (landing is `/wt-land`). Don't move another agent's work while it is inside the primary unless the user picked 1b. Don't pull or reset `<default>`. Don't delete a worktree folder wt kept.
