import type { Part } from "./layout.ts";
import type { Action } from "./state.ts";
import { readMemoryTally } from "../../shared/memory-tally.ts";

/**
 * The memory footer segment: one glyph and the count of what the next session
 * is given, painted as a single part so it hovers and clicks as one control.
 * The count turns to the warning colour once something is stale or entries have
 * started going cold, which is the only signal a reader needs from a distance.
 *
 * `undefined` when there is nothing to say, so the extension's own status text
 * stays for a session that has this package loaded without a tally.
 */
export const memoryParts = (open: Action): Part[] | undefined => {
  const tally = readMemoryTally();
  if (!tally) return undefined;
  if (tally.count === 0) return [];
  const alarm = tally.stale > 0 || tally.cold > 0;
  return [
    {
      id: "memory",
      text: `✦ ${tally.count}${tally.stale > 0 ? ` · ${tally.stale} stale` : ""}`,
      color: alarm ? "warning" : "dim",
      action: open,
    },
  ];
};
