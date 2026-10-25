import { getSubagentsService } from "@gotgenes/pi-subagents";
import type { Part } from "./layout.ts";
import type { Action } from "./state.ts";

// Font Awesome "users". One space follows the glyph: these fonts draw it into
// its own cells, so a second one reads as a gap.
const ICON_AGENTS = "";

/**
 * The subagents footer segment: one glyph and the running and queued tallies,
 * painted as a single part so it hovers and clicks as one control; `open` shows
 * the full list. The widget above the editor already names each agent, so the
 * package's own status sentence would only compete with it.
 *
 * `undefined` when the package publishes no service, so its status text stays.
 */
export const agentParts = (open: Action): Part[] | undefined => {
  const service = getSubagentsService();
  if (!service) return undefined;
  let running = 0;
  let queued = 0;
  for (const agent of service.listAgents()) {
    if (agent.status === "running") running++;
    else if (agent.status === "queued") queued++;
  }
  if (running + queued === 0) return [];
  return [
    {
      id: "agents",
      text: `${ICON_AGENTS} ${running}${queued > 0 ? ` +${queued}` : ""}`,
      color: "dim",
      action: open,
    },
  ];
};
