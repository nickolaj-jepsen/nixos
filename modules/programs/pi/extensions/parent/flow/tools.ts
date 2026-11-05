/**
 * The two tools a flow's skills drive (C3): `flow_next`, which ends the current
 * step and has the conductor advance once the turn settles, and `flow_status`,
 * the only way a skill reads FLOW.json.
 *
 * Both are plain functions over an injected context, so a unit test drives them
 * without pi; the registration, the schemas and the events are the feature
 * entry's (`../flow.ts`).
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  type Flow,
  type FlowBudget,
  type FlowStatus,
  modeOf,
  type Step,
  type ResolvedSettings,
} from "./contracts.ts";
import { budgetOf, diffLines, flowOf, transitionOf, writeFlow } from "./state.ts";

/**
 * A step whose advance is in flight. `flow_next` sets it so a second call in
 * the same turn is a no-op; `flow_next` asks, `agent_settled` fires one
 * `/flow next`, and a command cannot run mid-turn without tearing the session
 * down (notes/pi-api.md §2).
 */
export type Runtime = {
  /** The advance the tool asked for, sent as `/flow next` once the turn settles. */
  request?: { planDir: string; step: Step };
  /** The advance already requested for this step, so a repeat is a no-op. */
  advancing?: { planDir: string; step: Step };
};

export const createRuntime = (): Runtime => ({});

export type ToolDeps = {
  runtime: Runtime;
  now: () => number;
  /** Whether a subagent is still working; a session switch aborts it (D26). */
  hasRunning: () => boolean;
  /** What this session's transcript has cost so far, in USD. */
  cost: (ctx: ExtensionContext) => number;
};

/** A tool answer: the text the model reads, and whether it is a refusal. */
export type ToolOutcome = { text: string; isError?: boolean };

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

/** The cost this session has spent, or 0 when the transcript cannot be priced. */
const spent = (deps: ToolDeps, ctx: ExtensionContext): number => {
  try {
    return deps.cost(ctx);
  } catch {
    return 0;
  }
};

/**
 * Queues the current step's advance for `agent_settled`, optionally leaving a
 * note on its record. The conductor closes and prices the step only after the
 * owner accepts the transition, immediately before the session switch. Refuses
 * while a subagent runs, because that switch aborts it (D26), and repeats a
 * no-op for the same step.
 */
export const nextTool = (deps: ToolDeps, ctx: ExtensionContext, note?: string): ToolOutcome => {
  const found = flowOf(ctx);
  if (found.kind === "none")
    return {
      text: "flow_next only works inside a flow session; start one with /flow <slug>.",
      isError: true,
    };
  if (found.kind === "corrupt") return { text: `flow_next refused: ${found.error}`, isError: true };
  const flow = found.flow;
  const here = { planDir: flow.planDir, step: flow.step };
  if (deps.runtime.advancing?.planDir === here.planDir && deps.runtime.advancing.step === here.step)
    return { text: `flow: the ${flow.step} step is already advancing; one /flow next is queued.` };
  if (deps.hasRunning())
    return {
      text: "flow_next refused: a subagent is still running, and the next step's session switch would abort it. Wait for it to finish, then call flow_next again.",
      isError: true,
    };
  if (note !== undefined) {
    let index = -1;
    for (let cursor = flow.steps.length - 1; cursor >= 0; cursor -= 1) {
      const record = flow.steps[cursor];
      if (record.step === flow.step && record.endedAt === undefined) {
        index = cursor;
        break;
      }
    }
    // A step with no record (a brief started in an unsaved session) still
    // advances: its note is only in this answer, with nowhere to keep it.
    if (index >= 0) {
      const steps = flow.steps.slice();
      steps[index] = { ...steps[index], note };
      try {
        writeFlow({ ...flow, steps });
      } catch (error) {
        return {
          text: `flow_next refused: FLOW.json could not be written: ${message(error)}`,
          isError: true,
        };
      }
    }
  }
  deps.runtime.advancing = here;
  deps.runtime.request = here;
  const next = transitionOf(flow.step, modeOf(flow));
  return {
    text: `flow: the ${flow.step} step asked to advance${next ? `; /flow next moves to ${next.to}` : ""} once this turn settles.${note === undefined ? "" : `\nNote: ${note}`}`,
  };
};

/**
 * What `flow_status` answers: where the flow is, the settings resolved for it,
 * and the budget, whose caps come from the handoff and whose spend is what the
 * steps' session ledgers (judge calls included) have cost so far.
 */
export const statusOf = (
  deps: ToolDeps,
  ctx: ExtensionContext,
  flow: Flow,
  settings: ResolvedSettings,
): FlowStatus => {
  const record = flow.steps[flow.steps.length - 1];
  const live = record && record.step === flow.step && record.endedAt === undefined;
  const spentStep = live ? spent(deps, ctx) : (recordCost(flow, flow.step) ?? 0);
  // A judge's call is billed to the ledger of the step it ran in, so the step
  // costs already hold it; `flow.judge` keeps its cost for display only.
  const ended = flow.steps.reduce((sum, entry) => sum + (entry.cost ?? 0), 0);
  const budget: FlowBudget = {
    ...budgetOf(flow.planDir),
    spentStep,
    spentTotal: ended + (live ? spentStep : 0),
    lines: diffLines(flow.repoMain, flow.base, flow.branch),
  };
  return {
    slug: flow.slug,
    planDir: flow.planDir,
    repoMain: flow.repoMain,
    base: flow.base,
    branch: flow.branch,
    step: flow.step,
    mode: flow.mode,
    quick: flow.quick,
    settings,
    budget,
  };
};

/** The price a closed step recorded, if that step has one. */
const recordCost = (flow: Flow, step: Step): number | undefined => {
  for (let index = flow.steps.length - 1; index >= 0; index -= 1) {
    const record = flow.steps[index];
    if (record.step !== step) continue;
    return record.cost;
  }
  return undefined;
};
