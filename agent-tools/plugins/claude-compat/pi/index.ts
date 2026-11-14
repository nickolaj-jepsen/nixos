/** Claude Code habits in pi; one failing to load must not stop the other. */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import aliases from "./aliases.ts";
import stash from "./stash.ts";

export default function (pi: ExtensionAPI) {
  for (const feature of [aliases, stash]) {
    try {
      feature(pi);
    } catch (error) {
      pi.on("session_start", (_event, ctx) => {
        ctx.ui.notify(
          `claude-compat failed to load: ${error instanceof Error ? error.message : String(error)}`,
          "error",
        );
      });
    }
  }
}
