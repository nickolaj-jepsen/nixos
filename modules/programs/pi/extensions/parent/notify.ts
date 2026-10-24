/**
 * Desktop toasts through `agent-notify`, the script Claude Code's and
 * Copilot's Notification hooks use: when a run blocks on a dialog (permission,
 * question) and when a run finishes. agent-notify skips the toast while the
 * terminal window is focused and closes it once the window gets focus.
 * Also rings the terminal bell, like Claude Code's terminal_bell channel, which
 * sets niri's urgency hint.
 *
 * A finished run's toast says what it wants from you: chrome's identity reads
 * the settled turn with a sidecar call, and the toast waits briefly for it.
 */
import { spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { SIDECAR_CHANNEL, type SidecarUpdate } from "../shared/sidecar.ts";
import { trackUserWait, waitingOnUser } from "./lib/user-wait.ts";

// The settle call usually lands in a second or two; past this a plain toast beats a late one.
const SETTLE_WAIT_MS = 5_000;

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

/** The toast body for a finished run, from the sidecar's reading of it when there is one. */
const finished = (update: SidecarUpdate | undefined) => {
  if (update?.state === "blocked" && update.ask) return `Needs you: ${update.ask}`;
  const label = update?.label ? `: ${update.label}` : "";
  if (update?.state === "failed") {
    return `Stuck${label}${update.summary ? `\n${update.summary}` : ""}`;
  }
  if (update?.state === "done") return `Done${label}`;
  return "Finished, waiting for input";
};

export default function (pi: ExtensionAPI) {
  trackUserWait(pi);
  /** The settle reading of the current run, once it arrives. */
  let settled: SidecarUpdate | undefined;
  let waiter: ((update: SidecarUpdate) => void) | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let unsubscribe: (() => void) | undefined;

  const cancel = () => {
    if (timer) clearTimeout(timer);
    timer = undefined;
    waiter = undefined;
  };

  pi.on("session_start", () => {
    unsubscribe?.();
    unsubscribe = pi.events.on(SIDECAR_CHANNEL, (data) => {
      const update = data as SidecarUpdate;
      if (update.moment !== "settle") return;
      settled = update;
      waiter?.(update);
    });
  });
  pi.on("agent_start", () => {
    cancel();
    settled = undefined;
  });
  pi.on("ui_prompt_start", (event, ctx) => {
    if (waitingOnUser(ctx)) notify(ctx, event.title ?? "Needs your input");
  });
  pi.on("agent_settled", (event, ctx) => {
    if (event.aborted) return;
    const sessionId = ctx.sessionManager.getSessionId();
    // Identity may announce before or after this handler runs.
    if (settled?.sessionId === sessionId) {
      notify(ctx, finished(settled));
      return;
    }
    cancel();
    waiter = (update) => {
      if (update.sessionId !== sessionId) return;
      cancel();
      notify(ctx, finished(update));
    };
    timer = setTimeout(() => {
      cancel();
      notify(ctx, finished(undefined));
    }, SETTLE_WAIT_MS);
    timer.unref?.();
  });
  pi.on("session_shutdown", () => {
    cancel();
    unsubscribe?.();
    unsubscribe = undefined;
  });
}
