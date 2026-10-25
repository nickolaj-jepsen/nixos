/**
 * The editor's top border and the suggestion on the line under the input. The
 * border carries the label, the step in flight while the agent works or what the
 * finished turn wants from you, pi's scroll hint, the state word and the
 * measurements. pi's working spinner sits in front of the label, and a retry,
 * compaction or branch summary takes its place. The suggestion offers the drafted
 * reply in place, after the cursor, while the prompt is still empty.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import type { BorderStatus } from "./editor.ts";
import type { Identity } from "../identity.ts";
import type { Region } from "./layout.ts";
import type { Segment } from "./measurements.ts";
import type { ChromeState } from "./state.ts";

// Hover id of the top-border label.
const LABEL_ID = "label";
// Below this the label stops being the point of the row, so shed the detail first.
const MIN_LABEL_ROOM = 14;
// A step cut shorter than this says nothing worth the columns.
const MIN_DOING_ROOM = 8;
// An ask is a sentence beside the label; cut to a word or two it says nothing.
const MIN_ASK_ROOM = 14;

export const createBorder = (state: ChromeState, label: Identity) => {
  /**
   * One continuous line, inset like the footer's text: the leading and trailing
   * dashes stand in for its padding, and the detail is separated by the same
   * dashes instead of dots so the row reads as the top of the input box.
   * Detail is shed before the label is shortened.
   */
  const borderSides = (
    width: number,
    hidden: number,
    border: (text: string) => string,
    status: BorderStatus | undefined,
    levels: readonly Segment[][],
  ): { left: string; right: string; label?: { x0: number; x1: number }; controls: Region[] } => {
    const ctx = state.ctx;
    if (!ctx) return { left: "", right: "", controls: [] };
    const theme = ctx.ui.theme;
    const current = label.current(ctx);
    const name = current?.text ?? "";
    const detail = label.detail();
    // An ask already fills this row with what the turn wants, so the state word is
    // only for the two things that row cannot say: a dialog holding the run, and a
    // turn that gave up. The title keeps the word for every state.
    const word = label.stateWord(ctx);
    const stateText = word === "waiting" || word === "failed" ? word : undefined;
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
      // lead + label + hint + space, then the detail, then at least one dash.
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
      // The step gives way before the label is shortened: it is the part that can lie.
      const roomForDetail = room - visibleWidth(shown) - 3;
      const minDetail = label.asking() ? MIN_ASK_ROOM : MIN_DOING_ROOM;
      const shownDetail =
        detail && shown === name && roomForDetail >= minDetail
          ? truncateToWidth(detail, roomForDetail, "…")
          : undefined;
      const painted =
        current?.source === "prompt"
          ? theme.fg("dim", shown)
          : state.hover === LABEL_ID
            ? theme.fg("text", shown)
            : border(shown);
      const detailLine = shownDetail
        ? `${theme.fg("dim", " · ")}${theme.fg("dim", shownDetail)}`
        : "";
      const x0 = visibleWidth(lead);
      return {
        left: `${lead}${painted}${detailLine}${theme.fg("dim", hint)}${name ? " " : ""}`,
        right,
        label: name ? { x0, x1: x0 + visibleWidth(shown) } : undefined,
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
    levels: readonly Segment[][] = [],
  ): { line: string; regions: Region[] } => {
    const sides = borderSides(width, hidden, border, status, levels);
    const { left, right, controls } = sides;
    const fill = Math.max(0, width - visibleWidth(left) - visibleWidth(right));
    const rightStart = visibleWidth(left) + fill;
    return {
      line: left + (fill > 0 ? border("─".repeat(fill)) : "") + right,
      // The label and the measurements that carry an action; the rest is plain border.
      regions: [
        ...(sides.label
          ? [
              {
                ...sides.label,
                id: LABEL_ID,
                action: (ctx: ExtensionContext) => label.refresh(ctx, true),
              },
            ]
          : []),
        ...controls.map((c) => ({ ...c, x0: rightStart + c.x0, x1: rightStart + c.x1 })),
      ],
    };
  };

  /**
   * The draft that answers the finished turn's ask, offered on the line you are
   * about to type on: `room` is what the row has left after the cursor, so the
   * suggestion costs the box no row of its own.
   *
   * It exists only while the editor is empty, so it is never something to delete
   * before typing, and it is dropped as soon as you do type.
   */
  const hint = (room: number, empty: boolean): { ghost: string } | undefined => {
    const ctx = state.ctx;
    if (!ctx || !state.live) return undefined;
    if (!empty) {
      label.dropReply();
      return undefined;
    }
    const reply = label.reply();
    if (!reply) return undefined;
    // A cue plus a fragment of draft, or it is not worth the columns.
    const cue = "⇥ ";
    if (room < 12 + visibleWidth(cue)) return undefined;
    // Dim, because text at the cursor's weight would read as something already typed.
    const text = truncateToWidth(reply, room - visibleWidth(cue), "…");
    return { ghost: ctx.ui.theme.fg("dim", cue + text) };
  };

  return { drawTop, hint, takeHint: label.takeReply };
};
