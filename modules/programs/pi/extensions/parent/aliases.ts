/**
 * Claude Code's slash habits in pi, which matches built-in slash commands by
 * exact name, so muscle memory from other agents would land as a prompt.
 */
import { getSupportedThinkingLevels } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// A name standing alone, so paths like /tmp/x never match; the separator after it is consumed.
const SKILL_TOKEN = /(?<=^|\s)\/(?:skill:)?([a-z0-9-]+)(?:$|[\s.,;:!?)])/g;

export default function (pi: ExtensionAPI) {
  pi.registerCommand("clear", {
    description: "Start a new session (alias for /new)",
    handler: async (_args, ctx) => {
      await ctx.newSession();
    },
  });

  pi.registerCommand("effort", {
    description:
      "Set the thinking level: /effort <level>. Without one, show it and the allowed levels",
    handler: async (args, ctx) => {
      const allowed = ctx.model ? getSupportedThinkingLevels(ctx.model) : [];
      const wanted = args.trim().toLowerCase();
      const level = allowed.find((l) => l === wanted);
      if (!level) {
        const refused = wanted ? `No "${wanted}" effort on this model. ` : "";
        ctx.ui.notify(
          `${refused}Effort: ${pi.getThinkingLevel()} (allowed: ${allowed.join(", ") || "none"})`,
          refused ? "warning" : "info",
        );
        return;
      }
      pi.setThinkingLevel(level);
      ctx.ui.notify(`Effort: ${level}`, "info");
    },
  });

  // `/<skill>` anywhere invokes it: pi expands only a leading `/skill:<name>`, so hand it one with
  // the prompt as its arguments. The name must end at a space, which pi splits on.
  pi.on("input", (event) => {
    if (event.source === "extension" || event.text.startsWith("/skill:")) return;
    const skills = new Set(
      pi
        .getCommands()
        .filter((c) => c.source === "skill")
        .map((c) => c.name.slice("skill:".length)),
    );
    const token = [...event.text.matchAll(SKILL_TOKEN)].find((m) => skills.has(m[1]));
    if (!token) return;
    const text =
      token.index === 0
        ? `/skill:${token[1]} ${event.text.slice(token[0].length)}`
        : `/skill:${token[1]} ${event.text}`;
    return { action: "transform", text };
  });
}
