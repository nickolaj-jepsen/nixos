/**
 * Desktop toasts through `agent-notify`, the script Claude Code's and
 * Copilot's Notification hooks use: when a run blocks on a dialog (permission,
 * question) and when a run finishes. agent-notify skips the toast while the
 * terminal window is focused and closes it once the window gets focus.
 * Also rings the terminal bell, like Claude Code's terminal_bell channel, which
 * sets niri's urgency hint.
 */
import { spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { trackUserWait, waitingOnUser } from "./lib/user-wait.ts";

function notify(ctx: ExtensionContext, message: string) {
  // Print/JSON/RPC runs and subagents are scripted; nobody is waiting at a terminal.
  if (ctx.mode !== "tui" || !ctx.hasUI) return;
  process.stdout.write("\x07");
  // On PATH only on Linux desktops; elsewhere the spawn fails and is ignored.
  const child = spawn("agent-notify", ["pi"], { stdio: ["pipe", "ignore", "ignore"] });
  child.on("error", () => {});
  child.stdin.on("error", () => {});
  child.stdin.end(JSON.stringify({ cwd: ctx.cwd, message }));
}

export default function (pi: ExtensionAPI) {
  trackUserWait(pi);
  pi.on("ui_prompt_start", (event, ctx) => {
    if (waitingOnUser(ctx)) notify(ctx, event.title ?? "Needs your input");
  });
  pi.on("agent_settled", (event, ctx) => {
    if (!event.aborted) notify(ctx, "Finished, waiting for input");
  });
}
