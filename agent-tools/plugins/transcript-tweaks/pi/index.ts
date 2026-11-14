/** Two transcript tweaks; one failing to load must not stop the other. */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import condense from "./condense.ts";
import gutter from "./gutter.ts";

export default function (pi: ExtensionAPI) {
  for (const feature of [gutter, condense]) {
    try {
      feature(pi);
    } catch (error) {
      pi.on("session_start", (_event, ctx) => {
        ctx.ui.notify(
          `transcript-tweaks failed to load: ${error instanceof Error ? error.message : String(error)}`,
          "error",
        );
      });
    }
  }
}
