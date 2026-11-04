---
name: flow-guide
description: Write a flow's REVIEW-GUIDE.md from the plan, the progress file and the branch diff, seed the same reading order as a tuicr tour, and print the /rv line that reopens it.
disable-model-invocation: true
argument-hint: "<plan-dir>"
---

# flow-guide

You close the flow: the branch is built, and a reviewer has to be able to read it without starting from the first hunk of a thousand-line diff. You write `REVIEW-GUIDE.md` in the plan directory and seed the tour that walks it.

- The argument is the plan directory, absolute. `HANDOFF.md` and `PROGRESS.md` are in it beside `BRIEF.md`.
- `flow_status()` gives the slug, plan directory, the repo's main checkout, base branch, integration branch, mode and budget. It is the only way to read `FLOW.json`; never open it.
- `flow_tour` and `flow_next` belong to the flow's guide session. Without them you are a subagent child: write `REVIEW-GUIDE.md`, report its path, and stop before step 4.

## Spine

1. **Read what the flow left.** `HANDOFF.md` in full for the mission, the smallest version and its `Not building:` list, the items with their `Owns`, the contracts, `## Review focus`, `## Stops` and the budget. `PROGRESS.md` for the items table and their acceptance results, the gate verdicts, `### Calls the build made`, `## Deferred simplifications`, `## Surprises and failed approaches` and `## Measurements`. Where the two disagree, `PROGRESS.md` is what happened.
2. **Read the branch.** From the main checkout: `git -C <repoMain> merge-base <base> <branch>` for the range's start, then `git -C <repoMain> diff --stat <from>..<branch>` for the shape, `git -C <repoMain> log --oneline <from>..<branch>` for the order the work landed in, and the diff itself, area by area, against the item that owns each file. You are the only agent that has seen all of it.
3. **Write `REVIEW-GUIDE.md`** in the plan directory, in the shape below. Name files and symbols, not line numbers: the tour carries the lines, and a guide that repeats them is wrong after the next commit.
4. **Seed the tour.** Call `flow_tour` with an `intro` (one paragraph: what this change is and how to approach it) and one stop per reading-order step, at most about fifteen:
   - `file` is a path the branch diff touches, `line` (and `endLine` for a range) is a line that diff changes on the `new` side, unless the stop is about what a line replaced, in which case `side` is `old`. Get the numbers from `git -C <repoMain> diff --unified=0 <from>..<branch>`; the tool refuses a line the diff does not contain, because tuicr stores it and never renders it.
   - `type` is `issue`, `suggestion`, `nit`, `note` or `praise`. Use `note` to explain why a file is in the reading order, `issue` only where a reviewer should push back.
   - `body` is one or two sentences on what to look for at that line. A stop that repeats the guide adds nothing: the tour is for the reviewer following the diff, not a second index.
   - A stop with no `file` is review-level and renders above the diff; use it only if the intro is somehow not enough.
5. **Print the `/rv` line** `flow_tour` returned, verbatim, in a fenced block, with one sentence on what it opens. That exact argv is what reopens the session: another range, another checkout or a `/rv changes` gets a session without the tour in it.
6. **End the step** with `flow_next` and a one-line `note`: the stops seeded, where the guide points first, and anything you could not verify. Don't run a reviewer, don't fix code, and don't switch sessions.

## Shape

```markdown
# <title>: review guide

<One paragraph: what the branch does, in the terms a reviewer needs, and one line on how to read it.>

## Reading order

1. `<path or symbol>` — <why this is first: the decision everything else follows from>.
2. …

## Areas

### Core

- **<area>** — <what it does and why it exists>. Touched by <item IDs>.

### Mechanical

- **<area>** — <renames, generated files, moves: skim, don't read>.

## Look hard here

- <the risk: what could be wrong, in which file or symbol, and what a reviewer should try to break>.

## What was verified, and how

- <acceptance command or check>: <result, and where it ran>.
- <what nobody ran, and why>.

## Calls the build made

- <the non-deviation Default the run overturned, the evidence, and what it changes for a reader>.

## Deferred simplifications

- <the structural suggestion left for the owner, its size, and why it was not applied>.
```

## Rules

- The reviewer is a person deciding whether to land this. Say what the change does and why, where it is dangerous, and what the verdict already rests on; do not summarize the diff back at them.
- `## Calls the build made` and `## Deferred simplifications` come from `PROGRESS.md`; copy what is there and leave out headings with nothing under them. Never invent a call the run did not record, and never move a deferred simplification out of the list by silently applying it.
- Honest about what was not verified. An acceptance nobody ran, a device check left open and a red test all belong in the guide, not in a footnote.
- No secrets, tokens or personal data, and no status or dates: the guide describes the change, and `PROGRESS.md` already holds the run.
- The tour is part of the guide, not decoration. Seed it once, from the same order the guide prints, and check `flow_tour`'s answer: if it refuses a stop, fix the number and call it again rather than dropping the stop.
