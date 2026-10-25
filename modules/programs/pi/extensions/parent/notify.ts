/**
 * Rings the terminal bell when a run blocks on a dialog and when it finishes,
 * like Claude Code's terminal_bell channel; the bell sets niri's urgency hint.
 * Desktop toasts come from agent-hub, which sees every session.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Services } from "./services.ts";

function bell(ctx: ExtensionContext) {
  // Print/JSON/RPC runs are scripted; nobody is waiting at a terminal.
  if (ctx.mode === "tui" && ctx.hasUI) process.stdout.write("\x07");
}

export default function (pi: ExtensionAPI, { userWait }: Services) {
  pi.on("ui_prompt_start", (_event, ctx) => {
    if (userWait.waitingOnUser(ctx)) bell(ctx);
  });
  pi.on("agent_settled", (event, ctx) => {
    if (!event.aborted) bell(ctx);
  });
}
