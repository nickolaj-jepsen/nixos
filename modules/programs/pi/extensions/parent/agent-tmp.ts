/**
 * The agent temp line. Shows what this session's TMPDIR and the whole agent
 * temp root hold, and — when the disk is nearly full — appends one line to a
 * tool result so the session holding the space hears about it from the inside.
 *
 * The deleting belongs to `agent-tmp sweep` on a timer
 * (modules/programs/agent-tmp.nix, docs/agent-tmp.md). This only reports, from
 * the numbers that sweep leaves cached, and reads nothing itself: a `du` per
 * turn would cost more than the disk it watches.
 */
import { execFile } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const STATUS_KEY = "agent-tmp";
/** Long enough for a metadata walk, short enough that a stuck one is dropped. */
const TIMEOUT_MS = 10_000;

/** `agent-tmp` output, empty when it is not installed or has nothing to say. */
const run = (args: string[]) =>
  new Promise<string>((resolve) => {
    execFile("agent-tmp", args, { encoding: "utf8", timeout: TIMEOUT_MS }, (_error, stdout) =>
      resolve((stdout ?? "").trim()),
    );
  });

export default function (pi: ExtensionAPI) {
  /** Print/JSON/RPC runs have no footer, and a subagent's dir is some parent's. */
  const refresh = async (ctx: ExtensionContext) => {
    if (ctx.mode !== "tui" || !ctx.hasUI) return;
    const text = await run(["statusline"]);
    ctx.ui.setStatus(STATUS_KEY, text === "" ? undefined : text);
  };

  pi.on("session_start", (_event, ctx) => refresh(ctx));
  // A run's temp growth lands between turns, not inside one.
  pi.on("agent_settled", (_event, ctx) => refresh(ctx));

  pi.on("tool_result", async (event, ctx) => {
    const line = await run(["warnline", ctx.sessionManager.getSessionId()]);
    if (line === "") return;
    return {
      content: [...event.content, { type: "text", text: `\n${line}` }],
      // Dropping this would silently strip the machine-readable result of any
      // tool that declares an output schema.
      ...(event.structuredContent === undefined
        ? {}
        : { structuredContent: event.structuredContent }),
    };
  });
}
