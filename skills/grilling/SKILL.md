---
name: grilling
description: Interview the user relentlessly about a plan, design or decision until reaching shared understanding, asking the decision tree in rounds. Use when the user wants a plan stress-tested or asks to be grilled, or when another skill says to grill.
---

Interview the user relentlessly until you reach a shared understanding. Map the subject as a design tree: every decision branches into the decisions that hang off it.

## Rounds

The frontier is every decision whose prerequisites are settled: the questions you can ask now without guessing at answers you haven't heard. Ask the whole frontier in one round, then wait for the answers. A question that depends on another question still open in this round belongs to a later round. Answers move the frontier outward; recompute it from scratch each round.

Word each question so "yes" accepts your recommendation. Where a decision has real alternatives, list them as lettered options.

Format a round like so, with `---` between questions:

```
**Q1. <question>**

<optional body: context, lettered options>

> **Recommended:** <answer>, and the short reason.

---

**Q2. <question>**
...
```

Use the question tool instead (AskUserQuestion, `questions`) only when every question in the round is simple: at most four, each a pick from 2–4 short options, the recommended option first and labelled "(Recommended)". One question that needs a considered answer makes the whole round markdown, with the simple questions as lettered options. Never split a round between the two: the dialog can hide text written before it. Without a question tool, use markdown.

## Facts and decisions

Finding facts is your job: never ask the user what the environment can answer (code, config, docs, the web). Look small facts up inline before sending the round. Give research longer than a few tool calls to a background subagent with a narrow brief, and send the round without the questions that wait on it; they join a later round once it reports.

Decisions are the user's. Put each one to them and wait; never answer your own.

## Ending

The session is done when the frontier is empty: every branch visited, nothing silently assumed. Ask whether you've reached a shared understanding, and don't act on any of it until the user confirms.
