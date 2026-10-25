/**
 * Memory: a small, verified, per-worktree store of the things an agent with
 * this repo checked out would otherwise get wrong.
 *
 * What it deliberately is not:
 * - not a log. Nothing is extracted automatically, no daily notes, no summary
 *   written at exit. Only explicit saves, and only through a gate.
 * - not free-form. A save carries a citation that has to resolve now, a reason
 *   the repo cannot answer the question, and a statement that is not status.
 * - not authoritative. Entries are evidence with a citation and a freshness
 *   verdict; whatever the agent observes now wins.
 *
 * The store is Markdown, one file per memory; the hot section is a hard-capped
 * digest rendered once per session and frozen so the prompt prefix stays
 * cached. The rest stays on disk, where the agent reads it with its own tools.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerCommands } from "./memory/commands.ts";
import { createSessions } from "./memory/session.ts";
import { loadStore } from "./memory/store.ts";
import { registerTools } from "./memory/tools.ts";

export default function (pi: ExtensionAPI) {
  const sessions = createSessions();

  pi.on("session_start", async (_event, ctx) => {
    const session = sessions.begin(ctx);
    if (session.scope.orphans.length > 0 && ctx.hasUI) {
      const count = session.scope.orphans.reduce(
        (sum, store) => sum + loadStore(store).entries.length,
        0,
      );
      if (count > 0)
        ctx.ui.notify(
          `${count} memor${count === 1 ? "y" : "ies"} left by removed worktrees: /memory promote`,
          "info",
        );
    }
  });

  pi.on("session_shutdown", async (_event, ctx) => sessions.end(ctx));

  pi.on("before_agent_start", (event, ctx) => {
    const session = sessions.get(ctx);
    const options = event.systemPromptOptions;
    // pi's own context discovery, --append-system-prompt included, for the save gate.
    session.contextText = [
      options.appendSystemPrompt,
      ...options.contextFiles.map((file) => file.content),
    ].join("\n");
    if (session.injected) options.sections.memory = session.injected;
    else delete options.sections.memory;
  });

  registerTools(pi, sessions);
  registerCommands(pi, sessions);
}
