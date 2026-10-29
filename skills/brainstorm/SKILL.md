---
name: brainstorm
description: Find an approach for a goal that has none yet — settle the facts, ask a round or two of clarifying questions, propose 2–3 genuinely different approaches side by side, and stop once the user picks. Use when the user wants options before committing to a direction.
disable-model-invocation: true
argument-hint: "[goal]"
arguments: goal
---

`goal` is what to find an approach for; empty means what the conversation is about. This skill finds the approach. It doesn't settle the approach's details, write a design or touch code.

1. **Facts first.** Read what the goal touches: the code, config and docs, and how similar things are already done here. Never ask the user what you can look up.
2. **Clarify.** Ask only what would change which approaches are on the table: the goal behind the ask, hard constraints, what's already ruled out. Aim for one or two rounds, more only when the answers leave the options unclear, and none when the context already answers them. A round is numbered questions, each worded so "yes" accepts the `> **Recommended:**` blockquote under it. Use the question tool when every question is a short pick (at most four, 2–4 options each, recommended first); otherwise markdown.
3. **Propose approaches.** Two or three that differ in structure or trade-off, not variations of one idea, each checked against the code it would touch. Include a smaller-scope or don't-build-it option when it's real. If only one approach is reasonable, say so and present it alone rather than padding with straw men.

   Present them through the question tool: one option per approach, its name as the label, its main trade-off as the description, and a preview with the sketch, pros and cons, plus a snippet or layout where it helps. Put the recommended approach first, labelled "(Recommended)"; "Other" is how the user combines or rejects them. Without a question tool, write a markdown section per approach followed by your recommendation.

4. **Stop.** Restate the chosen approach in a few lines, then one line naming the next steps: grill it, annotate a plan, or build. Start none of them.
