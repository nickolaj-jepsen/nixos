---
name: plain
description: How to write prose a person will read, so it is short, clear and readable at a glance. Load before writing docs, a README, a PR description, a message to a person (email, Slack, an issue), a plan or design doc, a research report, or an agent context file (a skill, AGENTS.md, CLAUDE.md, memory). Not for commit messages, short code comments, handoffs or dispatch briefs. `/plain` turns it on for chat replies too; `/plain review [diff|branch|<path>]` reviews existing prose.
argument-hint: "[review [diff|branch|<path>]]"
---

Write for the reader, not about the work. These rules apply to everything you write while this skill is loaded, chat replies included.

1. Write for a reader who hasn't seen your work: not your tool calls, the files you opened or your reasoning. Cut what they already know or don't need.
2. Open with the result, the answer, or what you need from the reader. Background goes after.
3. Short, but never cryptic. Define a name you coined while working, or use plain words instead. Show a concrete example or sketch whenever a question or design is abstract.
4. Use bullets or a table for separate items, and prose where the reasoning connects (because, so, unless). Draw a diagram only for a real flow: calls between parts, a sequence, states.
5. Say the fact instead of announcing it. "This is the key insight" and "here's why it matters" add nothing; the next sentence is the point. One habit on its own is fine; several together is what reads as AI.

Formatting:

- No em-dashes: use a colon, a comma or a new sentence.
- Bold lead-ins only in reference lists, where each bullet names a term or option. Not in replies, messages or plans.
- No headers in a chat reply or a message.

Before writing, read the file for the kind of writing at hand in `references/`: `docs.md`, `comments.md` (docstrings and comments), `prs.md` (PR descriptions and commits), `messages.md`, `plans.md`, `reports.md` or `agent-context.md`. A repo's own writing rules (its AGENTS.md, contributing docs) win over these, and so does a format another skill or plugin sets.

## Check once, then stop

After drafting, one pass:

- Is the answer or ask in the first sentence?
- Is every name defined, and every abstract point shown with an example?
- Do several of rule 5's habits cluster anywhere?
- If you rewrote something, did any fact, name or number get lost?

For docs and reports over about 100 lines, also hand the draft to a fresh subagent with no context, plus five questions its reader would come with. Fix what it gets wrong or can't answer, once.

## Review mode

`/plain review` checks existing prose against these rules and the matching reference file. The target is `diff` by default (prose added or changed in `git diff HEAD`), `branch` (changed against the default branch) or a path. Edit in place, then list each change in a line. Leave code, generated and vendored files alone, and never commit.
