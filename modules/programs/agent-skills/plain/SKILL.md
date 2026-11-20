---
name: plain
description: Write and revise documentation, READMEs, PR descriptions, plans, reports and agent instructions for their intended reader. Use for a single passage or to organize and rewrite the surviving docs after a repository cleanup. Excludes routine code edits, commit messages, chat, handoffs and dispatch briefs. Use /plain explicitly for chat.
argument-hint: "[review [diff|branch|<path>]]"
---

# Plain

Start with what the reader came for. A returning maintainer may know the language and still need a map of this particular system. A user following a procedure needs the command they can actually run and some way to recognize success.

Follow explicit project requirements. Keep the local names, useful table columns and example formats a reader already knows. Dense neighboring prose can be rewritten. Give distinct ideas space, leave connected reasoning together and choose headings a reader would look for.

Read the reference for the work at hand:

- [Docs and READMEs](references/docs.md), including the shape of a whole repo.
- [Comments and docstrings](references/comments.md).
- [Pull requests](references/prs.md).
- [Plans and design docs](references/plans.md).
- [Reports](references/reports.md).
- [Agent instructions](references/agent-context.md).

For a documentation edit, check the facts that determine the reader's answer. For a procedure, follow it from its stated starting point where feasible. For an explanation, see whether it lets a reader predict what happens next. A fresh reader is especially valuable for onboarding, changed defaults or an unfamiliar architecture. Say which consequential step you could not verify.

## Review mode

`/plain review` edits the changed prose in the uncommitted diff by default. `branch` selects changed prose against the default branch. A path selects that file or directory. Respect the agreed removal scope when continuing a repo cleanup. Preserve public promises, meaningful qualifiers and author-owned decisions. Leave generated and vendored files to their owners. Summarize material changes and any unresolved factual question.
