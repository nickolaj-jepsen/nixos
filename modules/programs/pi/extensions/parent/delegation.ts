import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const DELEGATION_POLICY = `
Keep small tasks and planning with the main agent. Delegate only when independent work,
focused research/context preservation, or verification earns the coordination overhead.
A single focused researcher is useful even when there is nothing to parallelize.

Use explicit profiles: researcher, worker, reviewer, verifier are DeepSeek; expert is Sol 6.1.
Never spawn an unprofiled agent or override a routine profile to inherit the main model.
The main model is the user's choice; it is not part of the subagent allowance.

Sol experts are a last resort, not routine planners, workers or mandatory reviewers.
Use one only for a demonstrated hard blocker or consequential uncertainty that cheaper work
or direct work by the main agent cannot reasonably resolve. Explain the reason before spawning.
At most TWO Sol expert agents across the ENTIRE handoff/engagement, not per ticket, gate,
retry, session or milestone. Standalone work uses the same allowance per overall user task.
Reuse an existing expert with agent_send for follow-ups. Track the allowance conversationally;
do not create budget ledgers or reset it at ticket boundaries. If history no longer establishes
the allowance, ask the user rather than assuming a fresh budget. This is policy, not a hard quota.

Only the main agent delegates. Keep spawn:false and never enable nested delegation.
At most six subagents work concurrently. Parallel writers need separate worktrees or
genuinely disjoint owned paths, with shared decisions fixed before they start.
Never let two writers own the same files. Read-only profiles are behavioral contracts,
not security sandboxes: Bash and MCP/extension tools can still mutate state.

Each job must stand alone: objective, necessary decisions/evidence, owned paths and cwd,
constraints, acceptance criteria, and a concise output contract. Agents do not see this
conversation. Share relevant facts, not an entire transcript or your preferred verdict.
Use a fresh reviewer for independent judgment; do not automatically review every tiny edit.

agent_spawn always takes an agents array and returns immediately. Group jobs only when their
results belong together; no ceremonial agent pipelines. Results arrive asynchronously.
Do useful main-agent work while waiting. Use agent_wait directly only when the result is
needed now; it is unavailable inside codemode. Use agent_send to clarify, steer or continue
an existing agent, agent_status to inspect, and agent_stop to end work that is no longer needed.
A timed-out wait does not stop the work. Verify acceptance evidence before integrating;
a missing, capped or failed report is not success.
`.trim();

export default function delegation(pi: ExtensionAPI) {
  pi.on("before_agent_start", (event) => {
    event.systemPromptOptions.sections.delegation = DELEGATION_POLICY;
  });
}
