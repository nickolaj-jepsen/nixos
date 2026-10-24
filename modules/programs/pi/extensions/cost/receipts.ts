/**
 * Pane 2: the receipts. Every row's tokens and cost, the turns that cost the
 * most, and the figures the verdict rested on — for when a number on pane 1
 * raises a question. This is the only pane allowed to scroll.
 */
import type { Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { formatCost, formatTokens } from "../chrome/format.ts";
import type { Prompt, Row } from "./breakdown.ts";
import type { ItemKind } from "../lib/usage-ledger.ts";
import { barText, flow, heading, left, pctText, right, type Lines } from "./draw.ts";
import { rowLabel, type View } from "./view.ts";

// Width of each number column, its gap included.
const CALLS_W = 10;
const TOKENS_W = 9;
const COST_W = 10;
// Below this the token columns go; calls and cost stay.
const WIDE = 78;
// A budget and an idle cache are what a turn's bill is made of; either is worth a badge.
const TURNS_SHOWN = 5;
const BADGE_SHARE = 0.3;
const BADGE_W = 18;

const SECTIONS: ReadonlyArray<readonly [ItemKind, string]> = [
  ["conversation", "Conversation"],
  ["upkeep", "Upkeep"],
  ["side", "Side calls"],
  ["tool", "Tools"],
];

const tok = (n: number) => (n === 0 ? "·" : formatTokens(Math.round(n)));

/* -------------------------------------------------------------------- table */

const table = (view: View, theme: Theme, width: number): Lines => {
  const wide = width >= WIDE;
  // Two columns of padding on the right, as on the left.
  const nameW = Math.max(8, width - 2 - CALLS_W - (wide ? TOKENS_W * 4 : 0) - COST_W);
  const dim = (text: string) => theme.fg("dim", text);
  const lines: Lines = [];
  const header =
    right("calls", CALLS_W) +
    (wide
      ? right("input", TOKENS_W) +
        right("cached", TOKENS_W) +
        right("written", TOKENS_W) +
        right("output", TOKENS_W)
      : "") +
    right("cost", COST_W);

  for (const [kind, title] of SECTIONS) {
    const rows = view.breakdown.rows.filter((row) => row.kind === kind);
    if (rows.length === 0) continue;
    if (lines.length > 0) lines.push("");
    lines.push(left(heading(theme, title), nameW) + dim(header));
    for (const row of rows) {
      const u = row.usage;
      lines.push(
        `  ${theme.fg("text", left(rowLabel(view, row), nameW - 2))}` +
          dim(right(`${row.calls}${row.failed > 0 ? ` (${row.failed}✗)` : ""}`, CALLS_W)) +
          (wide
            ? theme.fg(
                "text",
                right(tok(u.input), TOKENS_W) +
                  right(tok(u.cacheRead), TOKENS_W) +
                  right(tok(u.cacheWrite), TOKENS_W) +
                  right(tok(u.output), TOKENS_W),
              )
            : "") +
          theme.fg("text", right(formatCost(u.cost.total), COST_W)),
      );
      const breakdown = row.kind === "tool" ? "" : split(row);
      if (breakdown) lines.push(dim(truncateToWidth(`    ${breakdown}`, width, "…")));
    }
  }
  return lines;
};

/** Where a row's money went, in the row's own terms. */
const split = (row: Row) => {
  const u = row.usage;
  const parts = (
    [
      ["in", u.cost.input],
      ["read", u.cost.cacheRead],
      ["write", u.cost.cacheWrite],
      ["out", u.cost.output],
    ] as const
  )
    .filter(([, usd]) => usd >= 0.0005)
    .map(([what, usd]) => `${what} ${formatCost(usd)}`);
  if ((u.cacheWrite1h ?? 0) > 0) {
    parts.push(`1h writes ${formatTokens(u.cacheWrite1h ?? 0)} of ${formatTokens(u.cacheWrite)}`);
  }
  return parts.join(" · ");
};

/* -------------------------------------------------------------------- turns */

/** What made a turn expensive, when one thing clearly did. */
const badge = (turn: Prompt): { text: string; color: ThemeColor } | undefined => {
  if (turn.usd <= 0) return undefined;
  if (turn.rebuilds > 0 && turn.rebuildUsd >= turn.usd * BADGE_SHARE) {
    return { text: `${turn.rebuilds} rebuild${turn.rebuilds === 1 ? "" : "s"}`, color: "warning" };
  }
  const top = turn.drivers[0];
  if (top && top.usd >= turn.usd * BADGE_SHARE) {
    return { text: `${top.name} ×${top.calls}`, color: "muted" };
  }
  return undefined;
};

const turns = (view: View, theme: Theme, width: number): Lines => {
  const spent = view.breakdown.timeline.filter((p) => p.usd > 0);
  if (spent.length === 0) return [];
  const top = [...spent].sort((a, b) => b.usd - a.usd).slice(0, TURNS_SHOWN);
  const peak = top[0]?.usd ?? 0;
  const lines: Lines = [
    "",
    heading(
      theme,
      "Costliest turns",
      `${top.length} of ${spent.length}, by cost · peak ${formatCost(peak)}`,
    ),
  ];
  for (const turn of top) {
    const lead = `  ${theme.fg("text", right(formatCost(turn.usd), 7))} ${theme.fg("muted", barText(turn.usd / peak, 8))} `;
    const mark = badge(turn);
    const room = width - 2 - visibleWidth(lead) - (mark ? BADGE_W : 0);
    const text = truncateToWidth(turn.text || "(no text)", Math.max(6, room), "…");
    lines.push(
      lead + theme.fg("text", text) + (mark ? right(theme.fg(mark.color, mark.text), BADGE_W) : ""),
    );
  }
  return lines;
};

/* -------------------------------------------------------------------- facts */

const facts = (view: View, theme: Theme, width: number): Lines => {
  const dim = (text: string) => theme.fg("dim", text);
  const lines: Lines = ["", heading(theme, "What the numbers rest on")];
  const notes: string[] = [];

  let input = 0;
  let read = 0;
  let write = 0;
  let saved = 0;
  let longTokens = 0;
  let premium = 0;
  for (const row of view.breakdown.rows) {
    if (row.kind === "tool") continue;
    input += row.usage.input;
    read += row.usage.cacheRead;
    write += row.usage.cacheWrite;
    saved += row.saved ?? 0;
    longTokens += row.usage.cacheWrite1h ?? 0;
    premium += row.longWrite?.premium ?? 0;
  }
  const promptTokens = input + read + write;
  if (promptTokens > 0) {
    notes.push(
      `cache ${pctText(read / promptTokens)} hit` +
        (saved >= 0.005 ? `, saved ≈${formatCost(saved)} at the input price` : ""),
    );
  }
  if (longTokens > 0) {
    notes.push(
      `1h retention ${formatTokens(longTokens)} of ${formatTokens(write)} written` +
        (premium >= 0.005 ? `, ${formatCost(premium)} above the 5m price` : ""),
    );
  }

  const levels = view.thinking
    .map((l) =>
      l.reasoning === undefined
        ? `${l.level} ${l.replies}× · reasoning not reported`
        : `${l.level} ${l.replies}× · ${pctText(l.output > 0 ? l.reasoning / l.output : 0)} of output · ${formatCost(l.reasoningUsd)}`,
    )
    .filter(Boolean);
  if (levels.length > 0) notes.push(`thinking ${levels.join(" · ")}`);

  const sources = view.context;
  if (sources.length > 0) {
    const now = view.contextTokens ?? sources.reduce((sum, s) => sum + s.now, 0);
    const shown = sources.slice(0, 3).map((s) => `${s.name} ${pctText(now > 0 ? s.now / now : 0)}`);
    const rest = sources.length - shown.length;
    notes.push(
      `context ${formatTokens(now)} · ${shown.join(" · ")}${rest > 0 ? ` · ${rest} more` : ""}`,
    );
  }

  // Which rebuilds were avoidable is a pane-1 cause; here there is room to say why.
  const idle = view.rebuilds.filter((r) => r.cause === "idle");
  if (idle.length > 0) {
    const longest = Math.max(...idle.map((r) => r.gap));
    notes.push(
      `idle rebuilds ${idle.length} of ${view.rebuilds.length}, longest ${Math.round(longest / 60)}m`,
    );
    const other = view.rebuilds.length - idle.length;
    if (other > 0) notes.push(`${other} from a model switch or a changed prefix`);
  }

  // Two columns of padding on the right, as on the left.
  for (const note of notes) {
    lines.push(...flow(note.split(" · ").map(dim), width - 2, dim(" · "), "  "));
  }
  return lines;
};

export const receipts = (view: View, theme: Theme, width: number): Lines => {
  if (view.breakdown.rows.length === 0) {
    return ["", theme.fg("dim", "  no priced request yet")];
  }
  return [
    "",
    ...table(view, theme, width),
    ...turns(view, theme, width),
    ...facts(view, theme, width),
  ];
};
