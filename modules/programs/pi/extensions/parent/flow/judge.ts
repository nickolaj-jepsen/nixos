/**
 * The judge (C4, D6): one flash side call that suggests the next step's model,
 * thinking level and (at the handoff) the run mode and item tiers, with a
 * one-line reason per choice.
 *
 * G0 ships the defaults as a stub; A3 replaces both functions with the real
 * calls. Neither may throw — a broken judge must never hold up a flow.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  DEFAULT_SETTINGS,
  type JudgeBriefVerdict,
  type JudgeHandoffVerdict,
  type ParsedHandoff,
  type ResolvedSettings,
} from "./contracts.ts";

const NOT_YET = "the judge is not implemented yet, so the defaults stand";

/** The plan step's suggestion: full or quick, and the model and level to run it on. */
export const judgeBrief = async (
  _pi: ExtensionAPI,
  _ctx: ExtensionContext,
  _brief: string,
  settings: ResolvedSettings,
): Promise<JudgeBriefVerdict> => ({
  plan: "full",
  model: settings.plan.model ?? DEFAULT_SETTINGS.plan.model ?? "vm/flash",
  thinking: settings.plan.thinking ?? "high",
  reasons: [NOT_YET],
  cost: 0,
});

/** The run's suggestion: mode, run step, item tiers, final reviewer. */
export const judgeHandoff = async (
  _pi: ExtensionAPI,
  _ctx: ExtensionContext,
  _handoff: ParsedHandoff,
  settings: ResolvedSettings,
): Promise<JudgeHandoffVerdict> => ({
  mode: "gated",
  run: {
    model: settings.run.model ?? DEFAULT_SETTINGS.run.model ?? "vm/flash",
    thinking: settings.run.thinking ?? "low",
  },
  tiers: {},
  finalReview: settings.finalReview.role ?? "reviewer-deep",
  reasons: [NOT_YET],
  cost: 0,
});
