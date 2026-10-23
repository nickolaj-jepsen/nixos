---
description: Fan out a multi-agent workflow over the current task
argument-hint: "[what to fan out over]"
---

Run a multi-agent workflow over ${@:-the task above}. This is my explicit opt-in to
that scale, so don't stop to ask whether to.

Scout inline first, so the script iterates a list that exists rather than a guess: name
the files, routes or channels the fan-out will cover. Then write the script and call
`SubagentWorkflow` — declared directly on large-context models, otherwise as
`tools.SubagentWorkflow` from codemode after `await describeTool("SubagentWorkflow")`.

Structure it: `meta` whose phase titles match the `phase()` calls, a discovery `agent()`,
then `parallel`/`pipeline` over what discovery returned, and a verification stage that
tries to refute each finding rather than one summariser. `gate` anything a command can
settle. Say what the workflow capped or dropped.
