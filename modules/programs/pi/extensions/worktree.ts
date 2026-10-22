/**
 * Keeps worktrees inside ~/worktrees/<repo>/ by refusing `git worktree add`
 * that would land anywhere else.
 *
 * The layout and the check live in `wt guard`, shared with the Claude Code hook
 * and the opencode plugin; this file is only pi's adapter. It blocks instead of
 * rewriting the command, so the model gets the real path back in the reason.
 */
import { spawnSync } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const fallback = "Blocked: git worktree add outside ~/worktrees/<repo>/. Use `wt create <name>`.";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", (event, ctx) => {
    if (event.toolName !== "bash") return;

    // `event.input` is unknown for custom tools, so read it structurally.
    const { command } = event.input as { command?: unknown };
    // Substring test first: spawning wt on every bash call would be waste.
    if (typeof command !== "string" || !command.includes("worktree")) return;

    const guard = spawnSync("wt", ["guard", command], { cwd: ctx.cwd, encoding: "utf8" });
    if (guard.error || guard.status !== 1) return;

    return { block: true, reason: guard.stdout.trim() || fallback };
  });
}
