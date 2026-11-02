/**
 * The hub's row for this session, painted as an alarm: the state the bar shows
 * the session in, which can outlast the turn in this TUI — an ask it is waiting
 * on, a turn that failed. `needs-reply` and `failed` carry the reason
 * behind them, since that is what there is to read; the words of the others say it all.
 *
 * Nothing is drawn while the hub has no row or the row is idle: those are the
 * sessions the bar shows no dot for either.
 */
import type { Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import type { Hub } from "../lib/hub.ts";
import type { HubState } from "../lib/protocol.gen.ts";
import { oneLine } from "../../shared/naming.ts";
import type { Part } from "./layout.ts";

type Look = { glyph: string; text: string; color: ThemeColor; reason: boolean };

// Font Awesome: a flag for what wants you, a cross for a failure, a check and a clock.
const LOOKS: Partial<Record<HubState, Look>> = {
  asking: { glyph: "\uf024", text: "asking", color: "error", reason: false },
  "needs-reply": { glyph: "\uf024", text: "needs reply", color: "warning", reason: true },
  failed: { glyph: "\uf00d", text: "failed", color: "error", reason: true },
  done: { glyph: "\uf00c", text: "done", color: "success", reason: false },
  working: { glyph: "\uf017", text: "working", color: "dim", reason: false },
};

// A reason is a sentence the hub wrote; the footer gives its width to the session's own line.
const REASON_MAX = 40;

export const hubParts = (hub: Hub): Part[] => {
  const row = hub.read();
  const look = row && LOOKS[row.state];
  if (!row || !look) return [];
  const word = `${look.glyph} ${look.text}`;
  const reason = look.reason ? oneLine(row.reason) : "";
  if (!reason) return [{ id: "hub", text: word, color: look.color }];
  const shown = reason.length > REASON_MAX ? `${reason.slice(0, REASON_MAX)}…` : reason;
  return [
    {
      id: "hub",
      text: `${word}: ${shown}`,
      color: look.color,
      // The state is what carries; the reason is there to read, not to shout.
      styled: (theme: Theme) => theme.fg(look.color, word) + theme.fg("dim", `: ${shown}`),
    },
  ];
};
