---
name: avoid-ai-tropes
description: Review human-facing prose (docs, READMEs, PR and commit descriptions, comments, release notes, a draft reply) against a catalog of recognizable AI writing tells, such as "delve", "it's not X -- it's Y", em-dash addiction, bold-first bullets and signposted conclusions, and rewrite it so it reads like a human wrote it. Optional target arg: diff (default), branch, or a path.
disable-model-invocation: true
argument-hint: "[diff|branch|<path>]"
arguments: target
---

# Avoid AI tropes

The catalog of tells in [references/catalog.md](references/catalog.md) comes from [tropes.fyi](https://tropes.fyi) by [ossama.is](https://ossama.is).

## Target

`$target` selects the prose to review (default `diff` when empty):

- `diff` (default): prose added or changed in the uncommitted diff (`git diff HEAD`). With a clean tree, the last draft you wrote in this conversation, such as a PR description or a reply meant to be published.
- `branch`: prose changed on this branch vs the default branch.
- a path: that file or directory.

Prose means documentation, READMEs, blog posts, PR and commit descriptions, comments, release notes. Leave code, generated and vendored files alone.

## How to review

1. Read [references/catalog.md](references/catalog.md) and check the draft against every trope in it.
2. Rewrite anything that matches.
   - A single pattern used once is usually fine.
   - The problem is several tropes appearing together, or one used repeatedly.
3. Aim for varied, imperfect, specific, human writing, not a mechanical strip of every flagged word.
