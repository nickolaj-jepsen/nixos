---
name: flow-brief
description: Write a flow's BRIEF.md from the conversation that started it — scope in and out, every decision tagged Yours or Defaults, and the questions still open — then hand the flow to its plan step.
disable-model-invocation: true
argument-hint: "<plan-dir>"
---

# flow-brief

You write a flow's `BRIEF.md`. You are the last session that holds the conversation this flow started from: every step after this one runs in a new session and reads only files, so what the brief leaves out is gone.

- The argument is the plan directory, absolute (`~/.local/share/agents/<project>/plans/<slug>/`). `FLOW.json` beside it is the flow's state.
- `flow_status` gives the flow's slug, the repo's main checkout, its base and its integration branch. Outside a flow session that tool is absent, which means you are a subagent child: write the file, report the path, and stop before step 7.
- `~/.agents/skills/handoff/SKILL.md` holds the rules this fork keeps, step 2 in particular. Read the steps you use rather than trusting a summary of them.

## Spine

1. **Read the conversation you are in.** What the owner settled, what they ruled out, and the reasons they gave. Where the session touched the repo, go back and read enough to be exact about a path, a command or a version instead of paraphrasing from memory.
2. **Harvest the decisions** by `~/.agents/skills/handoff/SKILL.md` step 2. A choice the owner stated, or picked against your recommendation, is theirs; a bare "yes", or a call you made yourself, is a Default; when the tag is unclear, it is a Default. One decision per bullet, with its `Why:` on the same bullet, because the plan copies these bullets into the handoff as they are.
3. **Write `BRIEF.md`** in the plan directory, in the shape below. Create the directory if it is missing. If a brief is already there, ask before overwriting it.
4. **Ask the owner to correct it.** One round covering what you got wrong or left out, and the open questions that are theirs to answer now. Use `ask_user_question` when every question in the round is a short pick, otherwise a numbered list with your recommended answer on each (`~/.agents/skills/grilling/SKILL.md` has the format). Don't ask what the session or the repo can answer: look those up.
5. **Fold the answers in.** An answer from the owner is theirs, so it lands under `### Yours` with the next `U<n>`, and a question it settles leaves `## Open questions`. Nothing is kept in your context that the file doesn't hold.
6. **Read it once more as the planner**, who never saw this chat: every term defined, no "as we discussed", every out-of-scope line said out loud. Fix what you find.
7. **End the step** with the `flow_next` tool and a one-line `note`: how many decisions, how many open questions. The conductor records the state and opens the plan step, where the owner confirms the model and whether the plan runs quick. Don't switch sessions yourself, don't start the work, and don't write `HANDOFF.md`.

## Shape

```markdown
# <title>: brief

## Mission

<One paragraph: what exists when this is done, and why the owner wants it.>

## Scope

In:

- <what this flow builds or changes>

Out:

- <what stays untouched, including what the owner ruled out and why>

## Locked decisions

### Yours

- U1 <decision>. Why: <the owner's reason>.

### Defaults

- D1 <decision>. Why: <reason>.

## Context

- Repo `<path>`, base branch `<base>`, integration branch `<branch>`.
- <what this session learned that research would otherwise find again: files, interfaces, versions, the commands that work here and how long they take>

## Open questions

- Q1 <the question, and how the plan should proceed while it is unanswered>

## Size and risk

<One or two lines: how big this is, what could make it hard, and what a smallest version would leave out. The judge reads this to pick the plan step's model and whether it runs quick.>
```

## Rules

- Short on purpose. The plan step reads this on an expensive model, so a page of decisions and a page of facts beats a transcript: write what the plan cannot re-derive.
- No secrets, tokens or personal data. Name where they live instead.
- Don't decompose, don't write acceptance commands, don't convene a grill. Sizing the smallest version is one line under `## Size and risk`, not a plan.
- The brief keeps the model and thinking level the session already runs on, so spend the turns you have on reading and asking rather than on prose.
- Status lives in `FLOW.json`, never in this file. IDs never renumber for the life of the flow.
