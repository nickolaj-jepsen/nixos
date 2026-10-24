---
description: Fan out a multi-agent workflow over the current task
argument-hint: "[what to fan out over]"
---

Run a multi-agent workflow over ${@:-the task above}. This is my explicit opt-in to
that scale, so don't stop to ask whether to.

Scout inline first, so the script iterates a list that exists rather than a guess: name
the files, routes or channels the fan-out will cover.

Then write one codemode script. `subagent` is codemode-only, so the first line is
`await describeTool("subagent")` when you don't have its parameters in front of you.

The shape:

- Launch every item with `run_in_background: true` and collect the ids. Four run at a
  time; the rest queue, so pass the whole list rather than batching it by hand.
- Wait with `get_subagent_result({ agent_id, wait: true })`, and use
  `Promise.allSettled` so one failed agent does not discard the others' results.
- For stages that depend on each other, give each item its own async chain and await
  the chains together. Waiting for a whole stage before starting the next one wastes
  the fast items' time.
- Ask for JSON only where the next step needs a field, and check it in the script:
  `JSON.parse` in a try block, then the fields you actually use. Text is fine
  everywhere else.
- Where a command can settle a claim, run it with `bash` and report its exit status
  instead of asking another model whether the work is good.
- An independent verifier per finding beats one summariser. Ask it to refute the
  finding, not to confirm it.

Say what the run capped or dropped: a truncated fan-out that reads as complete coverage
is worse than a smaller one that names its limits. Report the findings, not the script.
