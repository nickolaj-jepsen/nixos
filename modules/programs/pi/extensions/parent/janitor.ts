/**
 * The janitor's line for the model. When the disk is nearly full it appends one
 * line to a tool result, saying how much room there is and what this session's
 * own temp dir holds — the session holding the space hears about it from the
 * inside. Throttled by the CLI, so a run of tool calls cannot repeat it.
 *
 * Deleting belongs to `janitor` on a timer (modules/programs/janitor.nix,
 * docs/janitor.md). Nothing here reads the disk itself: the numbers come from
 * the sweep, and a `du` per turn would cost more than the disk it watches.
 */
import { execFile } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Long enough for a metadata walk, short enough that a stuck one is dropped. */
const TIMEOUT_MS = 10_000;

/** `janitor warnline` output, empty when it is not installed or has nothing to say. */
const warnline = (session: string) =>
  new Promise<string>((resolve) => {
    execFile(
      "janitor",
      ["warnline", session],
      { encoding: "utf8", timeout: TIMEOUT_MS },
      (_error, stdout) => resolve((stdout ?? "").trim()),
    );
  });

export default function (pi: ExtensionAPI) {
  pi.on("tool_result", async (event, ctx) => {
    const line = await warnline(ctx.sessionManager.getSessionId());
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
