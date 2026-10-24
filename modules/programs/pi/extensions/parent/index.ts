/**
 * The features only the session you started needs; subagent children never
 * load this package. One entry, so the features share one copy of each module
 * they import.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import aliases from "./aliases.ts";
import bg from "./bg.ts";
import browserGate from "./browser-gate.ts";
import chrome from "./chrome.ts";
import claudePeers from "./claude-peers.ts";
import condense from "./condense.ts";
import cost from "./cost.ts";
import gutter from "./gutter.ts";
import { trackUserWait } from "./lib/user-wait.ts";
import modelLabels from "./model-labels.ts";
import notify from "./notify.ts";
import spellfix from "./spellfix.ts";
import stash from "./stash.ts";
import subagentUsage from "./subagent-usage.ts";
import worktree from "./worktree.ts";

// Registration order is handler order: user-wait's state has to be current
// before anything reads it on ui_prompt_start.
const FEATURES: [string, (pi: ExtensionAPI) => void][] = [
  ["user-wait", trackUserWait],
  ["aliases", aliases],
  ["bg", bg],
  ["browser-gate", browserGate],
  ["chrome", chrome],
  ["claude-peers", claudePeers],
  ["condense", condense],
  ["cost", cost],
  ["gutter", gutter],
  ["model-labels", modelLabels],
  ["notify", notify],
  ["spellfix", spellfix],
  ["stash", stash],
  ["subagent-usage", subagentUsage],
  ["worktree", worktree],
];

export default function (pi: ExtensionAPI) {
  // One broken feature must not take the rest down with it.
  const failed: string[] = [];
  for (const [name, feature] of FEATURES) {
    try {
      feature(pi);
    } catch (error) {
      failed.push(`${name}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (failed.length === 0) return;
  pi.on("session_start", (_event, ctx) => {
    ctx.ui.notify(`Extensions failed to load:\n${failed.join("\n")}`, "error");
  });
}
