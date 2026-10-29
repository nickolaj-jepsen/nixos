---
name: annotate-plan
description: Plan a change in a PLAN.md the user annotates in their own editor — research the code, write the plan, fold the user's edits and inline notes in round after round until they approve, then implement on request with progress ticked off in the file. Use for a change too big to just start and too small for a handoff.
disable-model-invocation: true
argument-hint: "[task]"
arguments: task
---

`task` is the change to plan; empty means what the conversation is about. Write no code until the plan is approved and the user says to implement it.

## Setup

Pick a kebab-case topic. The plan is `<dir>/PLAN.md`, where `<dir>` is `<topic>/` under wherever the user's instructions keep long-lived agent notes, otherwise `.agents/plans/<topic>/` in the repo. If a `PLAN.md` is already there, ask whether to resume it or start over.

## First draft

Research the code the change touches: inline for a few reads, a subagent for a broad sweep. Don't ask clarifying questions first; gaps go under Open questions. Write `PLAN.md` with these sections:

- **Goal**: the outcome, in a sentence or two.
- **Findings**: what the code does today, with repo-relative paths.
- **Approach**: the shape of the change and why.
- **Changes**: what changes, per file or area.
- **Open questions**: calls you want the user to make.
- **Out of scope**

## Rounds

After every write, copy the plan to `PLAN.prev.md` beside it. End each round with the plan's absolute path, how many notes you addressed, which are still open, and "annotate and say go, or approve".

On go, diff `PLAN.md` against `PLAN.prev.md`. Every change is feedback, as is anything said in chat:

- An edit to your text is the user's wording now. Keep it.
- A deleted line means drop it.
- A note, in any style: fold it into the plan and remove it. If it's a question, you disagree, or the code contradicts it, leave it and add a blockquote under it starting `**Reply:**`. It stays open until the user's next pass.

## Approval

Only an explicit approval ends the loop. Then turn Changes into a checkbox list and ask whether to implement now.

If yes, implement in this session and tick each box in `PLAN.md` as it lands. If the code forces a departure from the plan, stop and ask before diverging. If no, stop and name the options: build later from the plan, or `/handoff` for work another agent should build.
