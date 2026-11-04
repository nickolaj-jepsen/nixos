/**
 * /flow: the command that turns the current session into the start of a
 * multi-step workflow (brief → plan → approve → run → guide), the two tools the
 * flow's skills call, and the footer segment naming the current step.
 *
 * This file is only the wiring: pi's registrations, its real judge, approval
 * page and cost, and the events the conductor hangs off. The machine is
 * `flow/conductor.ts`, the tools are `flow/tools.ts` and the state file is
 * `flow/state.ts`; each of those is testable without pi.
 */
import { getSubagentsService } from "@gotgenes/pi-subagents";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { buildBreakdown } from "./cost/breakdown.ts";
import { cacheRebuilds } from "./cost/rebuilds.ts";
import { approve } from "./flow/approval.ts";
import { command, type Deps, sessionStart, settled } from "./flow/conductor.ts";
import { TOOL_NEXT, TOOL_STATUS } from "./flow/contracts.ts";
import { judgeBrief, judgeHandoff } from "./flow/judge.ts";
import { flowOf, settingsOf } from "./flow/state.ts";
import { createRuntime, nextTool, statusOf } from "./flow/tools.ts";
import { registerTour } from "./flow/tour.ts";

/**
 * One runtime for the process, not one per extension instance: a step's session
 * switch re-runs the factory but not the module, and the queued `/flow next`
 * crosses that boundary (notes/testing.md §3).
 */
const runtime = createRuntime();

/** A session switch aborts a running subagent, so the advance waits for them (D26). */
const hasRunning = (): boolean => getSubagentsService()?.hasRunning() ?? false;

/** What a session's transcript has cost so far; `parent/cost.ts` builds the same breakdown. */
const cost = (ctx: ExtensionContext): number => {
  const entries = ctx.sessionManager.getEntries();
  return buildBreakdown(
    entries,
    cacheRebuilds(entries, (provider, model) => ctx.modelRegistry.find(provider, model)?.cost),
  ).total;
};

export default function (pi: ExtensionAPI) {
  registerTour(pi);

  // Each step session's model and level are applied here, in the new instance:
  // nowhere else in pi 1.5.0 can set them (notes/pi-api.md §1).
  pi.on("session_start", async (event, ctx) => {
    await sessionStart({ pi, ctx, now: Date.now }, runtime, event);
  });

  // `flow_next` cannot run `/flow next` itself: a command mid-turn tears the
  // session down. It queues the request and this sends it once the turn ends.
  pi.on("agent_settled", (event, ctx) => {
    settled(pi, runtime, event.aborted, ctx);
  });

  pi.registerCommand("flow", {
    description:
      "Flow steps: /flow <slug> starts one, /flow shows its status, /flow resume [slug] reopens one, /flow next advances.",
    handler: async (args, ctx) => {
      const deps: Deps = {
        pi,
        ctx,
        now: Date.now,
        hasRunning,
        cost,
        judgeBrief,
        judgeHandoff,
        approve,
      };
      try {
        await command(deps, runtime, args);
      } catch (error) {
        ctx.ui.notify(`flow: ${error instanceof Error ? error.message : String(error)}`, "error");
      }
    },
  });

  pi.registerTool({
    name: TOOL_NEXT,
    label: "Flow next",
    description:
      "End this /flow step and move to the next one: brief → plan → approve → run → guide → done. " +
      "The step's cost is recorded now, and the next step's session starts once this turn ends. " +
      "It refuses while a subagent is still running, and a repeat in the same turn is a no-op.",
    promptSnippet: "End the /flow step and advance to the next one",
    parameters: Type.Object({
      note: Type.Optional(
        Type.String({ description: "One line for the next step about what this one decided." }),
      ),
    }),
    async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
      const outcome = nextTool({ runtime, now: Date.now, hasRunning, cost }, ctx);
      return {
        content: [{ type: "text" as const, text: outcome.text }],
        details: undefined,
        isError: outcome.isError ?? false,
      };
    },
  });

  pi.registerTool({
    name: TOOL_STATUS,
    label: "Flow status",
    description:
      "This /flow's state as JSON: step, mode, quick, resolved step settings (models and roles), " +
      "the plan directory, the base and branch, and the budget (cost cap, spend per step and in total, diff lines and their cap).",
    promptSnippet: "Read this /flow's step, settings and budget",
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
      const here = flowOf(ctx);
      if (here.kind !== "ok")
        return {
          content: [
            {
              type: "text" as const,
              text:
                here.kind === "none"
                  ? "flow_status only works inside a flow session; start one with /flow <slug>."
                  : `flow_status refused: ${here.error}`,
            },
          ],
          details: undefined,
          isError: true,
        };
      const leaf = (pi.getSettings() as { flow?: unknown } | undefined)?.flow;
      const status = statusOf(
        { runtime, now: Date.now, hasRunning, cost },
        ctx,
        here.flow,
        settingsOf(leaf, here.flow).settings,
      );
      return {
        content: [{ type: "text" as const, text: JSON.stringify(status, null, 2) }],
        details: status,
        isError: false,
      };
    },
  });
}
