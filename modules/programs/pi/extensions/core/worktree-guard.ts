/**
 * Keeps worktrees inside ~/worktrees/<repo>/. The layout and the guard check
 * live in `wt`, shared with the Claude Code hook and the opencode plugin. The
 * guard blocks instead of rewriting the command, so the model gets the real
 * path back in the reason.
 */
import { spawnSync } from "node:child_process";
import { type ExtensionAPI, isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { BG_RUN } from "../shared/tools.ts";

const fallback = "Blocked: git worktree add outside ~/worktrees/<repo>/. Use `wt create <name>`.";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", (event, ctx) => {
    // bg_run is a shell too.
    const command = isToolCallEventType("bash", event)
      ? event.input.command
      : event.toolName === BG_RUN
        ? event.input.command
        : undefined;
    // Substring test first: spawning wt on every bash call would be waste.
    if (typeof command !== "string" || !command.includes("worktree")) return;

    const guard = spawnSync("wt", ["guard", command], { cwd: ctx.cwd, encoding: "utf8" });
    if (guard.error || guard.status !== 1) return;

    return { block: true, reason: guard.stdout.trim() || fallback };
  });
}
