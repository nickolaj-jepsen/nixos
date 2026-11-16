# Agent context files

Skills, AGENTS.md, CLAUDE.md and memory. An agent follows them, but a person edits them, and has to read each line and know what it makes the agent do.

- One rule per bullet: what to do, and when.
- The reason in a short clause after it, when it isn't obvious. An agent generalizes better from a reason than from a bare rule.
- Every term defined where it first appears, or replaced with plain words.
- Each rule makes sense on its own, without another bullet to explain it.
- Only what the agent wouldn't do anyway. Every line is paid for in context by every later session.
- Say what to do rather than listing what not to do. "Never" only for real absolutes.
- When editing one, cut before you add. A new rule that repeats an old one in other words replaces it.
- When rewriting a rule, keep its traps: the cases where the obvious action goes wrong. Those are what the rule is for.

## Example

```text
- Work in the checkout you are in, on its current branch (main included).
  Unless your work would conflict with the user's or another agent's current
  work, then use a worktree (using `wt`). Make sure to clean up worktrees and
  branches you create.
- The worktree tools (if existent) are integrated with `wt`, so use them
  rather than `wt` directly.

→
- Work in the current checkout and branch (main included). Use a worktree
  (the harness tool, else `wt new`) only if you'd conflict with other work.
```

Two bullets that depended on each other became one that says what to do and when.
