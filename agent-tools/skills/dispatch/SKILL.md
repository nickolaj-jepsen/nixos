---
name: dispatch
description: Write a lightweight requirements handoff for a small, settled task — use the existing conversation and only essential recon to produce REQUIREMENTS.md with scope, requirements, a suggested direction, key conversation context and references. No work items, implementation steps, subagents or verification plan. Use when the user asks for a small-task handoff, task brief or requirements file for another agent to implement.
disable-model-invocation: true
argument-hint: "[scope]"
arguments: scope
---

# dispatch

- The reader is an implementation agent that never saw this conversation.
- The conversation has already settled the task. Harvest it; don't restart brainstorming, grilling or research.
- Write requirements and a useful direction, not an implementation plan. Leave routine implementation choices to the builder.
- `scope` is free text naming what to include. Empty means the task the conversation just settled.

## Procedure

1. **Pin scope and destination, don't wait.** State in one line what is in scope, anything important left out, and the destination. Use a kebab-case slug and `plans/<slug>/REQUIREMENTS.md` in the project's store; `agent-notes root --ensure` gives its path, and the checkout sees it as `.agents/store`. Ask before overwriting an existing file.
2. **Harvest the conversation.** Capture the requested outcome, scope, explicit decisions and their rationale, rejected alternatives that matter, constraints, and references already mentioned. Preserve key points, not a transcript or a general summary. Preserve exact wording for load-bearing user constraints when paraphrase could change their meaning; don't quote ordinary discussion. Never re-litigate a settled choice.
3. **Do only essential recon.** Read files or docs directly implicated by the conversation, with at most one targeted search when needed to locate a reference. Stop as soon as the requirements, direction and references are grounded. No subagents, broad exploration, test runs, build verification or research fanout. State a remaining uncertainty rather than researching it away.
4. **Ask at most one question,** and only if a missing product decision prevents stating what should be built. Otherwise keep a genuine unresolved product question in the file; don't turn routine implementation unknowns into questions.
5. **Write `REQUIREMENTS.md`** from the template below. Normally keep it under 80 lines and omit empty sections. Do not create supporting research notes.
6. **Reread only the brief.** Remove references to "the discussion", undefined terms, accidental implementation steps and assertions the recon did not support. No cold-read subagent.
7. **Report only the path and kickoff:** `Read <path> and implement it.` Don't paste the brief back into chat.

If the task needs substantial discovery, work decomposition, contracts or explicit acceptance checks, say it needs `/handoff` instead; don't silently expand this skill into one.

## REQUIREMENTS.md

- Self-contained enough to understand the requirements, with repo-relative paths and exact symbols where known. Reference authoritative specs, plans, issues, commits, ADRs and code rather than reproducing them; restate only the decisions and constraints the builder needs.
- Requirements describe observable behavior and settled constraints, not how to implement them.
- Direction is a recommendation based on current context and light recon, not a locked decision unless the user explicitly made it one.
- References point to code, docs or external material worth reading first and say why each matters.
- Redact secrets and personal data.
- No work items, sequencing, owned paths, dependency graph, pseudocode, acceptance commands, test plan, review gates, stop conditions or generic guardrails.

```markdown
# <Title>: requirements

## Goal

<One or two sentences: the outcome and why it matters.>

**Done when:** <One observable condition, without prescribing test commands.>

## Scope

- In: <what this task covers>
- Out: <important exclusions>

## Requirements

- R1 <observable behavior or settled constraint>
- R2 <another requirement; include settled edge cases and decisions here>

## Direction

<One short paragraph: the suggested approach or code seam and why it fits. Name useful degrees of freedom or uncertainty without turning this into steps.>

## Conversation context

- <A key decision, rationale, rejected alternative or other point the builder needs; omit anything already fully captured above.>

## References

- `<path>` (`<symbol>`) — <why it is relevant>
- <document or URL> — <what it establishes>

## Open questions

<Only unresolved product questions the builder cannot answer. Omit when empty.>
```
