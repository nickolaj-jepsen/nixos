import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { AGENTS_STATE_EVENT, AGENTS_STATE_REQUEST_EVENT } from "./chrome/agents.ts";
import { createHerdrBridge } from "./herdr/bridge.ts";

const exec = promisify(execFile);

export default function herdr(pi: ExtensionAPI) {
  let bridge: Awaited<ReturnType<typeof createHerdrBridge>> | undefined;
  let unsubscribe: (() => void) | undefined;

  pi.on("session_start", async (_event, ctx) => {
    const hc = process.env.PI_HERDR_HC;
    const parent = process.env.HC_TERMINAL_ID;
    // Native Pi already reports the parent's status. Only mirror in-process
    // agents when the interactive session actually belongs to herdr-core.
    if (!hc || !parent || ctx.mode !== "tui") return;
    let warned = false;
    bridge = await createHerdrBridge({
      parent,
      sessionId: ctx.sessionManager.getSessionId(),
      cwd: ctx.cwd,
      monitor: fileURLToPath(new URL("./herdr/monitor.mjs", import.meta.url)),
      run: async (args) => (await exec(hc, args, { timeout: 5000, maxBuffer: 65536 })).stdout,
      onError: () => {
        if (warned) return;
        warned = true;
        ctx.ui.notify(
          "Herdr child-agent monitors unavailable; agents keep running in Pi.",
          "warning",
        );
      },
    });
    unsubscribe = pi.events.on(AGENTS_STATE_EVENT, (value) => bridge?.accept(value));
    pi.events.emit(AGENTS_STATE_REQUEST_EVENT, { protocol: 1 });
  });

  pi.on("session_shutdown", async () => {
    unsubscribe?.();
    unsubscribe = undefined;
    const old = bridge;
    bridge = undefined;
    await old?.dispose();
  });
}
