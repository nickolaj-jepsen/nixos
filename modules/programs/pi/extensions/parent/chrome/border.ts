/**
 * The editor's top border: the label, pi's scroll hint, the state word and the
 * measurements. pi's working spinner sits in front of the label, and a retry,
 * compaction or branch summary takes its place.
 */
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import type { BorderStatus } from "./editor.ts";
import type { Identity } from "../identity.ts";
import type { Region } from "./layout.ts";
import type { Segment } from "./measurements.ts";
import type { ChromeState } from "./state.ts";

// Below this the label stops being the point of the row.
const MIN_LABEL_ROOM = 14;

export const createBorder = (state: ChromeState, label: Identity) => {
  /**
   * One continuous line, inset like the footer's text: the leading and trailing
   * dashes stand in for its padding, and the measurements are separated by the
   * same dashes instead of dots so the row reads as the top of the input box.
   */
  const borderSides = (
    width: number,
    hidden: number,
    border: (text: string) => string,
    status: BorderStatus | undefined,
    levels: readonly Segment[][],
  ): { left: string; right: string; controls: Region[] } => {
    const ctx = state.ctx;
    if (!ctx) return { left: "", right: "", controls: [] };
    const theme = ctx.ui.theme;
    const current = label.current(ctx);
    const name = current?.text ?? "";
    const stateText = label.stateWord(ctx) || undefined;
    // pi reports scrolled editor content as `↑ N more`; it describes the editor,
    // so it belongs next to the label rather than in the session detail.
    const hint = hidden > 0 ? ` ↑${hidden}` : "";
    const stateSegment: Segment[] = stateText
      ? [{ text: theme.fg(stateText === "failed" ? "error" : "warning", stateText) }]
      : [];
    // Measurements give way before the state, which is the part that asks you to look.
    const rows: Segment[][] = [...levels.map((level) => [...stateSegment, ...level]), stateSegment];
    if (stateSegment.length > 0) rows.push([]);
    // A retry, compaction or branch summary takes the label's slot: it carries
    // the countdown and the key that cancels it.
    const message = status && status.kind !== "working" ? status : undefined;
    // pi's own shape, `── ⠋ Working`, with the label where its message would be.
    const lead =
      status?.kind === "working"
        ? `${border("──")} ${status.renderSpinnerInBorder(width)} `
        : border("── ");
    const separator = border(" ── ");
    const tail = border(" ──");

    for (const row of rows) {
      const right =
        row.length > 0 ? ` ${row.map((segment) => segment.text).join(separator)}${tail}` : "";
      // lead + label + hint + space, then at least one dash.
      const room = width - visibleWidth(lead) - visibleWidth(hint) - 2 - visibleWidth(right);
      if (room < MIN_LABEL_ROOM) continue;
      // Columns of the clickable measurements, counted from the start of `right`.
      const controls: Region[] = [];
      let column = 1;
      row.forEach((segment, index) => {
        if (index > 0) column += visibleWidth(separator);
        const segmentWidth = visibleWidth(segment.text);
        if (segment.id && segment.action) {
          const pad = segment.hitPad ?? 0;
          controls.push({
            x0: column - pad,
            x1: column + segmentWidth + pad,
            id: segment.id,
            action: segment.action,
          });
        }
        column += segmentWidth;
      });
      // A padded target must not swallow its neighbour: two of them split the gap
      // between them, so a click near the border, or the pointer's hover, still
      // picks the control it is closest to.
      for (let i = 1; i < controls.length; i++) {
        const left = controls[i - 1];
        const right = controls[i];
        if (left && right && left.x1 > right.x0) {
          const middle = Math.floor((left.x1 + right.x0) / 2);
          left.x1 = middle;
          right.x0 = middle;
        }
      }
      if (message) {
        return {
          left: `${lead}${message.renderInBorder(room)}${theme.fg("dim", hint)} `,
          right,
          controls,
        };
      }
      // The label wears the input's own border color (pi keys it to the
      // thinking level), so it reads as box chrome rather than prompt text.
      const shown = name ? truncateToWidth(name, room, "…") : "";
      const painted = current?.source === "prompt" ? theme.fg("dim", shown) : border(shown);
      return {
        left: `${lead}${painted}${theme.fg("dim", hint)}${name ? " " : ""}`,
        right,
        controls,
      };
    }
    return { left: "", right: "", controls: [] };
  };

  const drawTop = (
    width: number,
    hidden: number,
    border: (text: string) => string,
    status: BorderStatus | undefined,
    levels: readonly Segment[][],
  ): { line: string; regions: Region[] } => {
    const sides = borderSides(width, hidden, border, status, levels);
    const { left, right, controls } = sides;
    const fill = Math.max(0, width - visibleWidth(left) - visibleWidth(right));
    const rightStart = visibleWidth(left) + fill;
    return {
      line: left + (fill > 0 ? border("─".repeat(fill)) : "") + right,
      // The measurements that carry an action; the rest is plain border.
      regions: controls.map((c) => ({ ...c, x0: rightStart + c.x0, x1: rightStart + c.x1 })),
    };
  };

  return { drawTop };
};
