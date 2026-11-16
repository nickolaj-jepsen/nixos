---
name: plain
description: How to write prose a person will read, so it is clear, easy to skim and free of AI habits. Load before writing docs, a README, a PR description, a plan or design doc, a research report, or an agent context file (a skill, AGENTS.md, CLAUDE.md, memory). Not for commit messages, short code comments, chat messages, handoffs or dispatch briefs. `/plain` turns it on for replies in this session; `/plain review [diff|branch|<path>]` reviews existing prose.
argument-hint: "[review [diff|branch|<path>]]"
---

# Plain

Write for the reader, not about the work. These rules apply to everything you write while this skill is loaded.

## Rules

1. Write for a reader who wasn't there. They haven't seen your tool calls, the files you read or your reasoning. Leave out what they already know or don't need.
2. Open with the result, the answer, or what you need from the reader. Background comes after.
3. Easy to read beats short. Cut repetition, history and process, but keep every fact the reader needs to act correctly, gotchas most of all. Then give the rest room:
   - one idea per sentence, and two short sentences over one long one;
   - keep the small words that connect ideas (because, so, but, which);
   - paragraphs of three sentences or fewer.
4. Never cryptic. A name you coined, or a tool, flag or internal term the reader may not know, gets a clause saying what it is the first time it appears. Or use plain words instead. Show an example or sketch when a point is abstract.
5. Give the page a shape the reader can scan:
   - Headers for anything with more than one part: docs, PRs, plans, reports. Each names what is under it.
   - Bullets or a table for separate items. Three or more items in one sentence become a list.
   - A bullet holds one or two short sentences. One that needs more gets sub-bullets, or becomes a paragraph.
   - Prose where the reasoning connects.
   - A diagram only for a real flow: calls between parts, a sequence, states.
6. Say the fact instead of announcing it. "This is the key insight" and "here's why it matters" add nothing; the next sentence is the point. One habit on its own is fine. Several together is what reads as AI.

Formatting details:

- No em-dashes. Use a colon, a comma or a new sentence.
- Bold lead-ins only in reference lists, where each bullet names a term or option. A group label ("Claude Code:", "pi:") is a header or a parent bullet instead.
- A reply of a few paragraphs needs no headers.

## Genres

Before writing, read the file for the kind of writing at hand in `references/`:

- `docs.md`: docs and READMEs
- `comments.md`: docstrings and comments
- `prs.md`: PR descriptions and commits
- `plans.md`: plans and design docs
- `reports.md`: research reports and findings
- `agent-context.md`: skills, AGENTS.md, CLAUDE.md, memory

A repo's own writing rules (its AGENTS.md, contributing docs) win over these. So does a format another skill or plugin sets.

## Check once, then stop

After drafting, make one pass:

- Is the answer or ask in the first sentence?
- Does any sentence carry two ideas, any bullet run past two sentences, or any paragraph past three?
- Would a header or a list make a part easier to find?
- Is every name defined, and every abstract point shown with an example?
- Do several of rule 6's habits cluster anywhere?
- Is every concrete claim (a file, a count, a cause, an order of events) one you checked?
- If you rewrote something, did any fact, name or number get lost?

For docs and reports over about 100 lines, also hand the draft to a fresh subagent with no context. Give it five questions the reader would come with. Fix what it gets wrong or can't answer, once.

## Review mode

`/plain review` checks existing prose against these rules and the matching reference file. The target is one of:

- `diff` (default): prose added or changed in `git diff HEAD`
- `branch`: prose changed against the default branch
- a path

Edit in place, then list each change in a line. Leave code, generated and vendored files alone, and never commit.
