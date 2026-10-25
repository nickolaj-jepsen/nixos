/**
 * The memory tallies the footer paints: core publishes them when a session
 * starts, after a write and after an action; chrome reads them to draw the
 * glyph, the alarm colour and the click target. A module copy boundary sits
 * between the two packages, so this goes through the process global.
 *
 * The status text `ctx.ui.setStatus` sets is the repaint signal and the
 * fallback outside chrome; this is what a footer needs to render it properly.
 */
import { processGlobal } from "./process-global.ts";

export type MemoryTally = {
  /** Entries the next session will be given. */
  count: number;
  stale: number;
  cold: number;
};

const slot = () =>
  processGlobal<{ value?: MemoryTally }>("memory.tally", () => ({ value: undefined }));

/** Publishes the current tallies, or clears them when the session ends. */
export const publishMemoryTally = (value: MemoryTally | undefined) => {
  slot().value = value;
};

export const readMemoryTally = (): MemoryTally | undefined => slot().value;
