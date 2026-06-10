---
name: handoff-all
description: Split an entire list of suggestions into several standalone implementation plans, grouping related items so each plan can be handed to its own fresh agent.
argument-hint: Optional — how to group (e.g. "by file", "one plan per concern")
allowed-tools: Read, Write, Grep, Glob, Bash(mktemp:*)
disable-model-invocation: true
---

Take the entire list of items from the conversation and split it into several standalone plans, grouping items that make sense to implement together, so each plan can be handed to its own fresh agent.

First, identify the full list. Then group it. Cluster items that belong together by:

- Shared surface — same file, module, component, or subsystem.
- Shared concern — e.g. performance, security, accessibility, tests, types, docs.
- Dependency or ordering — items that must be done together or in sequence belong in the same plan.

Keep each group independently actionable: a fresh agent should be able to pick up one plan without needing the others or this conversation. If two items must ship together, put them in the same plan. Avoid one giant catch-all plan, and avoid scattering into trivial single-item plans unless an item is genuinely standalone. Name each group by its theme.

For each group, write one standalone plan to its own path produced by `mktemp -t handoff-plan-XXXXXX.md` (read each file before you write to it). Each plan contains, for every item in it:

- The suggestion itself, stated precisely.
- Why it was suggested — the problem it solves or the rationale.
- The concrete files, functions, components, or locations involved.
- Any decisions, constraints, or gotchas about it that surfaced in the conversation.
- A clear definition of done / acceptance criteria.

Within a plan, note any ordering between its items if it matters. Across plans, if one plan depends on another, mention it in a single line — don't fold the other plan's work in.

Suggest the skills, if any, each plan's session should use.

Do not duplicate content already captured in other artifacts (PRDs, plans, issues, tickets, commits, diffs). Reference them by path or URL instead.

Finish by printing a short index to the user: one line per plan giving its theme, the items it covers, and its file path, so they can see the grouping at a glance and dispatch the plans.

If the user passed arguments, treat them as steering for the grouping (e.g. "group by file", "keep the backend ones together", "one plan per concern") and follow that preference.
