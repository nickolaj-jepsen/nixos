/**
 * The features only the session you started needs; subagent children never
 * load this package. One entry, so the features share one copy of each module
 * they import, and what they share goes through `Services`.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import janitor from "./janitor.ts";
import aliases from "./aliases.ts";
import bg from "./bg.ts";
import browserGate from "./browser-gate.ts";
import chrome from "./chrome.ts";
import claudePeers from "./claude-peers.ts";
import condense from "./condense.ts";
import cost from "./cost.ts";
import gutter from "./gutter.ts";
import modelLabels from "./model-labels.ts";
import questions from "./questions.ts";
import notify from "./notify.ts";
import { createServices, type Services } from "./services.ts";
import spellfix from "./spellfix.ts";
import stash from "./stash.ts";
import subagentUsage from "./subagent-usage.ts";
import worktree from "./worktree.ts";

const FEATURES: [string, (pi: ExtensionAPI, services: Services) => void][] = [
  ["janitor", janitor],
  ["aliases", aliases],
  ["bg", bg],
  ["browser-gate", browserGate],
  ["chrome", chrome],
  ["claude-peers", claudePeers],
  ["condense", condense],
  ["cost", cost],
  ["gutter", gutter],
  ["model-labels", modelLabels],
  ["questions", questions],
  ["notify", notify],
  ["spellfix", spellfix],
  ["stash", stash],
  ["subagent-usage", subagentUsage],
  ["worktree", worktree],
];

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

export default function (pi: ExtensionAPI) {
  const failed: string[] = [];
  let services: Services | undefined;
  try {
    services = createServices(pi);
  } catch (error) {
    failed.push(`services: ${message(error)}`);
  }
  // One broken feature must not take the rest down with it.
  for (const [name, feature] of FEATURES) {
    if (!services) break;
    try {
      feature(pi, services);
    } catch (error) {
      failed.push(`${name}: ${message(error)}`);
    }
  }
  if (failed.length === 0) return;
  pi.on("session_start", (_event, ctx) => {
    ctx.ui.notify(`Extensions failed to load:\n${failed.join("\n")}`, "error");
  });
}
