/**
 * The approval page (C5, D13): before the run, the owner sees what will be
 * built and changed, the steps, the gates and every point the run may stop,
 * and edits the step settings, the mode, item tiers and open questions there.
 *
 * G0 ships a stub that approves unchanged; A2 replaces it with the overlay and
 * `APPROVAL.md`.
 */
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import type { Approval, Flow, JudgeHandoffVerdict, ParsedHandoff } from "./contracts.ts";

/** What the owner chose. The stub never asks; a real page answers approve, back or cancel. */
export const approve = async (
  _pi: ExtensionAPI,
  _ctx: ExtensionCommandContext,
  flow: Flow,
  _handoff: ParsedHandoff,
  _verdict: JudgeHandoffVerdict,
): Promise<Approval> => ({ kind: "approve", flow });
