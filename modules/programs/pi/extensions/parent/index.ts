/**
 * The features only the session you started needs; subagent children never
 * load this package. One entry, so the features share one copy of each module
 * they import, and what they share goes through `Services`.
 *
 * Spellfix, questions and worktree are agents plugins (`plugins/<name>/pi`)
 * rather than features here; the editor hooks this package publishes are how
 * spellfix still underlines chrome's prompt.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import bg from "./bg.ts";
import chrome from "./chrome.ts";
import claudePeers from "./claude-peers.ts";
import delegation from "./delegation.ts";
import notify from "./notify.ts";
import { createServices, type Services } from "./services.ts";

const FEATURES: [string, (pi: ExtensionAPI, services: Services) => void][] = [
  ["delegation", delegation],
  ["bg", bg],
  ["chrome", chrome],
  ["claude-peers", claudePeers],
  ["notify", notify],
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
