import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { AGENTS_STATE_EVENT, AGENTS_STATE_REQUEST_EVENT } from "./chrome/agents.ts";
import { createHerdrBridge } from "./herdr/bridge.ts";
import { createAgentContext } from "./herdr/context.ts";
const exec = promisify(execFile);

export default function herdr(pi: ExtensionAPI) {
  let bridge: Awaited<ReturnType<typeof createHerdrBridge>> | undefined;
  let context: ReturnType<typeof createAgentContext> | undefined;
  let unsubscribe: (() => void) | undefined;
  let timer: ReturnType<typeof setInterval> | undefined;
  const request = () => pi.events.emit(AGENTS_STATE_REQUEST_EVENT, { protocol: 1 });

  pi.on("session_start", async (_event, ctx) => {
    const parent = process.env.HC_TERMINAL_ID;
    // HC_TERMINAL_ID is the gate, not a wrapper-only opt-in. /reload should
    // work in an existing Herdr terminal whose environment predates the switch.
    if (!parent || ctx.mode !== "tui") return;
    const hc = process.env.PI_HERDR_HC || "hc";
    // Availability is local: don't start a permanent retry loop when an SSH or
    // container inherited the marker but has no core client installed.
    try {
      await exec(hc, ["--version"], { timeout: 5000 });
    } catch {
      ctx.ui.notify(
        "Herdr child monitors disabled: hc is unavailable. Install it, then /reload.",
        "warning",
      );
      return;
    }
    context = createAgentContext(ctx.cwd);
    context.restore(ctx.sessionManager.getBranch());
    let warned = false;
    bridge = await createHerdrBridge({
      parent,
      sessionId: ctx.sessionManager.getSessionId(),
      cwd: ctx.cwd,
      monitor: fileURLToPath(new URL("./herdr/monitor.mjs", import.meta.url)),
      context: (id, name) => context?.get(id, name) ?? {},
      run: async (args) => (await exec(hc, args, { timeout: 5000, maxBuffer: 1048576 })).stdout,
      onError: () => {
        if (warned) return;
        warned = true;
        ctx.ui.notify(
          "Herdr monitors temporarily unavailable; agents keep running. Retrying automatically (/herdr for status).",
          "warning",
        );
      },
    });
    unsubscribe = pi.events.on(AGENTS_STATE_EVENT, (value) => bridge?.accept(value));
    request();
    // Recover killed monitors and failed launches even if no lifecycle event
    // changes. Never allow overlapping health checks to pile up on a slow core.
    let checking = false;
    timer = setInterval(() => {
      if (checking || !bridge) return;
      checking = true;
      request();
      void bridge.refresh().finally(() => {
        checking = false;
      });
    }, 5000);
    timer.unref();
  });
  pi.on("session_tree", (_event, ctx) => {
    if (!bridge) return;
    context = createAgentContext(ctx.cwd);
    context.restore(ctx.sessionManager.getBranch());
    request();
    void bridge.refresh();
  });
  pi.on("tool_execution_start", (event) =>
    context?.start(event.toolCallId, event.toolName, event.args),
  );
  pi.on("tool_execution_end", (event) => {
    context?.result(event.toolCallId, event.toolName, event.result);
  });
  pi.registerCommand("herdr", {
    description: "Show child-monitor status; /herdr reconnect forces recovery",
    handler: async (args, ctx) => {
      if (!bridge) {
        ctx.ui.notify(
          "Child monitors need an interactive Pi session inside Herdr. After switching, restart Pi once to pick up its new package path.",
          "info",
        );
        return;
      }
      if (args.trim() === "reconnect") {
        request();
        await bridge.refresh();
      }
      const status = bridge.status();
      ctx.ui.notify(
        `Herdr: ${status.monitors}/${status.agents} read-only child monitors.${status.lastError ? " Core unavailable; automatic recovery is active." : " Connected."}`,
        status.lastError ? "warning" : "info",
      );
    },
  });
  pi.on("session_shutdown", async () => {
    if (timer) clearInterval(timer);
    timer = undefined;
    unsubscribe?.();
    unsubscribe = undefined;
    const old = bridge;
    bridge = undefined;
    context = undefined;
    await old?.dispose();
  });
}
