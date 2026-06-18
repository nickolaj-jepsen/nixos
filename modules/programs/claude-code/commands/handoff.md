---
name: handoff
description: Hand off the implementation of one or a few specific items from a longer list to a fresh agent, packaging only the context those items need.
argument-hint: Which item(s) from the list to hand off?
allowed-tools: Read, Write, Grep, Glob, Bash(mktemp:*)
disable-model-invocation: true
---

Write a focused handoff document so a fresh agent can implement only the selected item(s) from a longer list, with no dependence on the rest of this conversation.

First, identify which item(s) to hand off. If the user passed arguments, use them to select (by number, by name, or by paraphrase — match generously). If it's ambiguous which item they mean, ask before writing.

Then write the doc covering, for the selected item(s) only:

- The suggestion itself, stated precisely (not the list around it).
- Why it was suggested — the problem it solves or the rationale, so the next agent understands intent rather than just the instruction.
- The concrete files, functions, components, or locations involved.
- Any decisions, constraints, or gotchas about this item that surfaced in the conversation (e.g. "must stay backwards-compatible", "don't touch the legacy adapter").
- A clear definition of done / acceptance criteria.

Deliberately leave out the other items in the list and unrelated conversation context — the entire point is a narrow, self-contained brief. If a sibling item is a genuine dependency, mention it in one line as context, don't fold its work in.

Save the doc to a path produced by `mktemp -t handoff-XXXXXX.md` (read the file before you write to it).

Suggest the skills, if any, the next session should use to do the work.

Do not duplicate content already captured in other artifacts (PRDs, plans, issues, tickets, commits, diffs). Reference them by path or URL instead.
