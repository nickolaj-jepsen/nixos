---
description: Hand a sweep to cheap subagents and keep the judgment here
argument-hint: "[what to hand over]"
---

Delegate ${@:-the reading for the task above}. This is my explicit opt-in to spending
subagent tokens, so don't stop to ask whether to.

Do the cheap part inline first: name the files, directories or questions the sweep
covers, and the decision you need back from it. Then launch a few `Explore` agents
(`reviewer` for a second opinion) in the background.

- One child costs a launch and a report. That is a fair trade for a sweep, a search you
  would otherwise page through, or an independent second opinion, and a waste for one
  file you could have read.
- Give the child what it cannot infer: the paths, the question, what you already ruled
  out, and the shape of the answer you want. It has not seen this conversation.
- Keep judgment here: design, the review that decides something, and edits to files
  already in this context. A child's opinion is evidence, not a verdict.
- Ask for evidence one call can check: `path:line`, a command and its exit status, a
  quote. A claim you cannot check is worse than no answer.
- If a child comes back shallow or wrong, do the part yourself rather than re-delegating
  the same question, and say what changed.
- Report what the sweep found and what it did not cover.
