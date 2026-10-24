/**
 * The single drawing vocabulary the cost panes share. Money is drawn only as
 * eighth-block bars, quota only as a `━` track, and every figure is measured in
 * terminal columns rather than characters.
 */
import type { Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

export type Lines = string[];

const EIGHTHS = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"];

const clamp = (n: number) => Math.max(0, Math.min(1, Number.isFinite(n) ? n : 0));

/** A bar `cells` wide filled to `fraction`, in eighths; unpainted, padded with spaces. */
export const barText = (fraction: number, cells: number) => {
  const units = Math.round(clamp(fraction) * cells * 8);
  const text = "█".repeat(Math.floor(units / 8)) + EIGHTHS[units % 8];
  return text + " ".repeat(Math.max(0, cells - visibleWidth(text)));
};

/**
 * A quota gauge: the filled part in `color`, the remainder a `░` track. The two
 * glyphs differ, so a gauge still reads where money bars and colours do not.
 */
export const gauge = (theme: Theme, fraction: number, cells: number, color: ThemeColor) => {
  const filled = Math.round(clamp(fraction) * cells);
  return theme.fg(color, "━".repeat(filled)) + theme.fg("borderMuted", "░".repeat(cells - filled));
};

export const right = (text: string, width: number) =>
  " ".repeat(Math.max(0, width - visibleWidth(text))) + text;

export const left = (text: string, width: number) =>
  truncateToWidth(text, width, "…") + " ".repeat(Math.max(0, width - visibleWidth(text)));

export const heading = (theme: Theme, title: string, note = "") =>
  theme.fg("accent", theme.bold(title)) + (note ? theme.fg("dim", `  ${note}`) : "");

/** Joins `items` with `sep`, wrapping onto new lines rather than cutting one off. */
export const flow = (items: readonly string[], width: number, sep: string, indent = ""): Lines => {
  const out: Lines = [];
  let line = indent;
  for (const item of items) {
    const next = line === indent ? line + item : line + sep + item;
    if (line !== indent && visibleWidth(next) > width) {
      out.push(line);
      line = indent + item;
    } else {
      line = next;
    }
  }
  if (line !== indent) out.push(line);
  return out;
};

// Facts beside a label need this much room, or they move under it.
export const MIN_FACTS_W = 34;
const UNDER_INDENT = "      ";

/** `lead` followed by `facts`, wrapped beside it, or under it when the line is too narrow. */
export const besideOrUnder = (
  lead: string,
  facts: readonly string[],
  width: number,
  sep: string,
  minRoom = MIN_FACTS_W,
) => {
  const room = width - visibleWidth(lead);
  if (room >= minRoom) {
    // A fact too long for the gap beside the lead is cut, never pushed off the pane.
    const wrapped = flow(
      facts.map((fact) => truncateToWidth(fact, room, "…")),
      room,
      sep,
    );
    return [
      lead + (wrapped[0] ?? ""),
      ...wrapped.slice(1).map((more) => " ".repeat(visibleWidth(lead)) + more),
    ];
  }
  return [lead, ...flow(facts, width, sep, UNDER_INDENT)];
};

export const pctText = (fraction: number) => {
  const pct = fraction * 100;
  return pct > 0 && pct < 1 ? "<1%" : `${Math.round(pct)}%`;
};

export const usageColor = (pct: number): ThemeColor =>
  pct >= 90 ? "error" : pct >= 60 ? "warning" : "success";

/** A slice of money: `usd` of `total`, drawn in `color`. */
export type Slice = { label: string; usd: number; color: ThemeColor };

/** One full-width bar split by slice, cells shared out by largest remainder. */
export const stackedBar = (theme: Theme, parts: readonly Slice[], cells: number) => {
  const total = parts.reduce((sum, p) => sum + p.usd, 0);
  if (total <= 0) return theme.fg("borderMuted", "━".repeat(cells));
  const exact = parts.map((p) => (p.usd / total) * cells);
  const counts = exact.map(Math.floor);
  let spare = cells - counts.reduce((a, b) => a + b, 0);
  const order = exact.map((e, i) => [e - Math.floor(e), i] as const).sort((a, b) => b[0] - a[0]);
  for (const [, i] of order) {
    if (spare <= 0) break;
    counts[i]! += 1;
    spare -= 1;
  }
  return parts.map((p, i) => theme.fg(p.color, "█".repeat(counts[i]!))).join("");
};
