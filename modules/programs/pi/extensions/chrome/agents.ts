import type { Part } from "./layout.ts";
import type { Action } from "./state.ts";

// The agent package publishes its footer line as prose for a human reader ("2
// running, 1 queued agents"). The widget above the editor already names each
// agent and what it is doing, so repeating the sentence here only competes with
// it; the footer keeps the tallies behind one glyph.
const RUNNING = /(\d+) running/;
const QUEUED = /(\d+) queued/;

// Font Awesome "users". One space follows the glyph: these fonts draw it into
// its own cells, so a second one reads as a gap.
const ICON_AGENTS = "\uf0c0";

const count = (pattern: RegExp, text: string) => {
  const match = pattern.exec(text);
  return match ? Number(match[1]) : 0;
};

/**
 * The subagents footer segment: one glyph and the tallies, painted as a single
 * part so it hovers and clicks as one control; `open` shows the full list.
 *
 * Takes the package's status text, or `undefined` when it published none, and
 * returns nothing it cannot parse.
 */
export const agentParts = (text: string | undefined, open: Action): Part[] => {
  if (text === undefined) return [];
  const running = count(RUNNING, text);
  const queued = count(QUEUED, text);
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
