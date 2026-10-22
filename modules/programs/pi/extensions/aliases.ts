/**
 * `/clear` does what `/new` does. Pi matches built-in slash commands by exact
 * name, so muscle memory from other agents lands as a prompt instead.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerCommand("clear", {
    description: "Start a new session (alias for /new)",
    handler: async (_args, ctx) => {
      await ctx.newSession();
    },
  });
}
