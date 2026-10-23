/**
 * Asks before the first chrome-devtools MCP call of a session; a yes covers the
 * rest of it. pi-permission-system can't express this: its session approval
 * for an MCP tool covers only that one tool, so every browser tool would ask.
 *
 * Nested calls (codemode scripts) go through `tool_call` too, so they are gated.
 * Without a UI (print mode) the browser stays blocked.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Pi's tool-name spelling of the `chrome-devtools` server in the pi leaf's MCP config.
const PREFIX = "mcp__chrome_devtools__";
const ALLOW = "Allow for this session";

export default function (pi: ExtensionAPI) {
  let approved = false;
  // Concurrent calls from one script share a single prompt.
  let asking: Promise<boolean> | undefined;

  pi.on("session_start", () => {
    approved = false;
    asking = undefined;
  });

  pi.on("tool_call", async (event, ctx) => {
    if (approved || !event.toolName.startsWith(PREFIX)) return;
    if (!ctx.hasUI)
      return {
        block: true,
        reason: "Browser use needs the user's approval, and no UI is available.",
      };

    asking ??= ctx.ui
      .select("The agent wants to drive a browser (chrome-devtools, its own profile).", [
        ALLOW,
        "Deny",
      ])
      .then((choice) => choice === ALLOW)
      .finally(() => (asking = undefined));
    approved = await asking;
    if (!approved)
      return {
        block: true,
        reason: "The user denied browser use for now; don't retry unless asked.",
      };
  });
}
