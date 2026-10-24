/**
 * Pane 1: what this session cost and why, in the order the money was spent.
 *
 * The driver list is a partition: every dollar of the total appears exactly
 * once, as one of the six cost components or as a tool row of its own. The
 * causes below it are not a partition — each names a cause inside one of the
 * drivers and its dollars, which is why they are never summed.
 */
import type { Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";
import { formatCost, formatCredit, formatTokens } from "../chrome/format.ts";
import type { Row } from "./breakdown.ts";
import {
  barText,
  besideOrUnder,
  flow,
  heading,
  left,
  pctText,
  right,
  type Slice,
  stackedBar,
  type Lines,
} from "./draw.ts";
import { billed, onPlans, rowLabel, type View } from "./view.ts";

/* ------------------------------------------------------------------ drivers */

/** A tool row is named, so only the costliest few earn a line of their own. */
const TOOL_DRIVERS = 3;

type Driver = Slice & { cause: string };

/** The prompt-side costs of everything that is not a tool row. */
const components = (view: View) => {
  let input = 0;
  let read = 0;
  let write = 0;
  let long = 0;
  let output = 0;
  const tools: Row[] = [];
  for (const row of view.breakdown.rows) {
    const cost = row.usage.cost;
    if (row.kind === "tool") {
      tools.push(row);
      continue;
    }
    input += cost.input;
    read += cost.cacheRead;
    output += cost.output;
    // Without a catalog price the 1h share can't be told apart from the 5m one.
    const longUsd = Math.min(row.longWrite?.usd ?? 0, cost.cacheWrite);
    long += longUsd;
    write += cost.cacheWrite - longUsd;
  }
  return { input, read, write, long, output, tools };
};

/** Rebuilds, reasoning and the 1h premium, each attributed to the driver it sits in. */
const causes = (view: View) => {
  const rebuiltUsd = view.rebuilds.reduce((sum, r) => sum + r.usd, 0);
  const byCause = new Map<string, number>();
  for (const r of view.rebuilds) byCause.set(r.cause, (byCause.get(r.cause) ?? 0) + 1);
  const longest = Math.max(0, ...view.rebuilds.map((r) => r.gap));

  const reasoned = view.thinking.filter((l) => l.reasoning !== undefined);
  const reasoningTokens = reasoned.reduce((sum, l) => sum + (l.reasoning ?? 0), 0);
  const outputTokens = reasoned.reduce((sum, l) => sum + l.output, 0);
  const reasoningUsd = reasoned.reduce((sum, l) => sum + l.reasoningUsd, 0);
  const reasoningReplies = reasoned.reduce((sum, l) => sum + l.replies, 0);
  const level = [...view.thinking].sort((a, b) => b.reasoningUsd - a.reasoningUsd)[0]?.level;

  let longTokens = 0;
  let longPremium = 0;
  for (const row of view.breakdown.rows) {
    longTokens += row.usage.cacheWrite1h ?? 0;
    longPremium += row.longWrite?.premium ?? 0;
  }
  return {
    rebuiltUsd,
    rebuildCounts: byCause,
    longest,
    reasoningUsd,
    reasoningShare: outputTokens > 0 ? reasoningTokens / outputTokens : 0,
    reasoningReplies,
    level,
    longTokens,
    longPremium,
  };
};

const share = (name: string, view: View) => view.context.find((s) => s.name === name);

const driverList = (view: View): Driver[] => {
  const { input, read, write, long, output, tools } = components(view);
  const c = causes(view);
  const ctx = view.contextTokens;
  const promptTokens = input + read + write;
  const hit = promptTokens > 0 ? read / promptTokens : 0;
  const replies = share("replies", view);
  const contextNow = ctx ?? view.context.reduce((sum, s) => sum + s.now, 0);
  const repliesShare = rectified(replies, contextNow);

  const parts: Driver[] = [
    {
      label: "input",
      usd: input,
      color: "mdLink",
      cause: contextNow > 0 ? `${formatTokens(contextNow)} context, re-sent uncached` : "",
    },
    {
      label: "output",
      usd: output,
      color: "syntaxVariable",
      cause:
        c.reasoningShare >= 0.05
          ? `${pctText(c.reasoningShare)} of it is reasoning`
          : `${formatTokens(view.breakdown.rows.reduce((s, r) => s + r.usage.output, 0))} tokens`,
    },
    {
      label: "cache read",
      usd: read,
      color: "success",
      cause:
        c.rebuiltUsd >= 0.005
          ? `${formatCost(c.rebuiltUsd)} lost to rebuilds`
          : hit > 0
            ? `${pctText(hit)} hit rate`
            : "",
    },
    {
      label: "cache write 5m",
      usd: write,
      color: "warning",
      cause: write > 0 ? "kept warm for 5 min" : "",
    },
    {
      label: "cache write 1h",
      usd: long,
      color: "error",
      cause:
        c.longPremium >= 0.005
          ? `${formatCost(c.longPremium)} for the 1h tier`
          : long > 0
            ? "1h retention"
            : "",
    },
  ];

  const ranked = [...tools].sort((a, b) => b.usage.cost.total - a.usage.cost.total);
  for (const row of ranked.slice(0, TOOL_DRIVERS)) {
    const cached = row.usage.cacheRead + row.usage.cacheWrite;
    parts.push({
      label: rowLabel(view, row),
      usd: row.usage.cost.total,
      color: "muted",
      cause: [
        `${row.calls}×`,
        cached > 0 ? `${formatTokens(cached)} cached` : "",
        row.failed > 0 ? `${row.failed}✗` : "",
      ]
        .filter(Boolean)
        .join(" · "),
    });
  }
  const rest = ranked.slice(TOOL_DRIVERS);
  const folded = rest.reduce((sum, r) => sum + r.usage.cost.total, 0);

  // Rows whose components don't add up to their total (tiered or flat pricing).
  const other = view.breakdown.total - parts.reduce((sum, p) => sum + p.usd, 0) - folded;
  if (other > view.breakdown.total * 0.005) {
    parts.push({ label: "other", usd: other, color: "dim", cause: "tiered or flat pricing" });
  }
  const sorted = parts.filter((p) => p.usd > 0.00005).sort((a, b) => b.usd - a.usd);
  if (rest.length === 0) return sorted;

  // A folded row is a remainder, so it stays last however large it is.
  return [
    ...sorted,
    {
      label: `${rest.length} more tool${rest.length === 1 ? "" : "s"}`,
      usd: folded,
      color: "muted" as ThemeColor,
      cause: `in ${rest.reduce((sum, r) => sum + r.calls, 0)}×`,
    },
  ];
};

/** A share of `contextTokens`, guarding a source the branch never reported. */
const rectified = (source: { now: number } | undefined, total: number) =>
  source && total > 0 ? source.now / total : 0;

/* ------------------------------------------------------------------- causes */

// A cause needs both dollars and a share of the total, or it is noise.
const MIN_CAUSE_USD = 0.05;
const MIN_CAUSE_SHARE = 0.02;

// Kept to a word each: the whole spread has to fit one column.
const CAUSE_TEXT: Record<string, string> = {
  idle: "idle",
  "model switch": "model switch",
  "prefix changed": "prefix change",
};

const causeLines = (
  view: View,
  theme: Theme,
  width: number,
  detail: boolean,
  most: number,
  /** Width of the name column, so cause money lands where the drivers' money does. */
  labelW: number,
): Lines => {
  const c = causes(view);
  const total = view.breakdown.total;
  const floor = Math.max(MIN_CAUSE_USD, total * MIN_CAUSE_SHARE);
  const dim = (text: string) => theme.fg("dim", text);
  const rows: Array<{ label: string; usd: number; detail: string }> = [];

  if (c.rebuiltUsd >= floor) {
    const spread = [...c.rebuildCounts]
      .sort((a, b) => b[1] - a[1])
      .map(([cause, n]) => `${n}× ${CAUSE_TEXT[cause] ?? cause}`);
    rows.push({
      label: `${view.rebuilds.length} cache rebuild${view.rebuilds.length === 1 ? "" : "s"}`,
      usd: c.rebuiltUsd,
      detail: spread.join(", "),
    });
  }
  if (c.reasoningUsd >= floor) {
    rows.push({
      label: c.level ? `reasoning at ${c.level}` : "reasoning",
      usd: c.reasoningUsd,
      detail: `${pctText(c.reasoningShare)} of output, ${c.reasoningReplies} replies`,
    });
  }
  if (c.longPremium >= floor) {
    rows.push({
      label: "1h cache retention",
      usd: c.longPremium,
      detail: `${formatTokens(c.longTokens)} written, above the 5m price`,
    });
  }
  const input = components(view).input;
  const contextNow = view.contextTokens ?? view.context.reduce((sum, s) => sum + s.now, 0);
  if (input >= floor && contextNow > 0) {
    rows.push({
      label: "context re-sent",
      usd: input,
      detail: `${formatTokens(contextNow)} now, ${pctText(rectified(share("replies", view), contextNow))} of it replies`,
    });
  }
  const failed = view.breakdown.rows.reduce((sum, r) => sum + r.failedUsd, 0);
  const failedCount = view.breakdown.rows.reduce((sum, r) => sum + r.failed, 0);
  if (failed >= floor) {
    rows.push({ label: `${failedCount} failed replies`, usd: failed, detail: "billed anyway" });
  }

  const shown = rows.sort((a, b) => b.usd - a.usd).slice(0, most);
  if (shown.length === 0) {
    const reasoning = c.reasoningShare > 0 ? `, ${pctText(c.reasoningShare)} reasoning` : "";
    return [
      dim(
        `  nothing stood out — ${formatCost(total)} total, ` +
          `${view.rebuilds.length === 0 ? "no rebuilds" : `${view.rebuilds.length} rebuilds`}${reasoning}`,
      ),
    ].slice(0, most);
  }
  return shown.map(
    (r) =>
      `  ${theme.fg("text", left(r.label, labelW))}` +
      `${theme.fg("text", right(formatCost(r.usd), 9))}` +
      (detail ? `  ${dim(truncateToWidth(r.detail, width - labelW - 15, "…"))}` : ""),
  );
};

/* ----------------------------------------------------------------- headline */

const headline = (view: View, theme: Theme) => {
  const total = view.breakdown.total;
  const paid = billed(view.providers);
  const plan = onPlans(view.providers);
  // Under half a cent is not a charge worth naming.
  const charged = paid >= 0.005;
  const qualifier =
    !charged && plan <= 0
      ? "nothing billed"
      : plan > 0 && charged
        ? `list price · ${formatCost(paid)} billed, rest on plan`
        : plan > 0
          ? "list price · nothing billed"
          : "billed";
  return `${theme.bold(theme.fg("text", formatCost(total)))}${theme.fg("dim", `  ${qualifier}`)}`;
};

/** The scarce thing, in one line: plan windows and prepaid balances. */
const statusLine = (view: View, theme: Theme, width: number) => {
  const facts: string[] = [];
  for (const p of view.providers) {
    if (p.credit) {
      const left = p.credit.allowance > 0 ? p.credit.remaining / p.credit.allowance : 0;
      facts.push(
        theme.fg("dim", `${p.id} `) +
          theme.fg(
            left <= 0.05 ? "error" : left <= 0.2 ? "warning" : "success",
            formatCredit(p.credit.remaining),
          ) +
          theme.fg("dim", " left"),
      );
    }
    for (const w of p.windows ?? []) {
      const grew = Math.round(w.delta) > 0;
      facts.push(
        theme.fg("dim", `${w.label} `) +
          theme.fg(
            w.usedPct >= 90 ? "error" : w.usedPct >= 60 ? "warning" : "success",
            `${Math.round(w.usedPct)}%`,
          ) +
          (grew ? theme.fg("warning", ` +${Math.round(w.delta)}`) : ""),
      );
    }
  }
  if (facts.length === 0) return [];
  return flow([theme.fg("dim", "quota"), ...facts], width, theme.fg("dim", " · "), "  ");
};

/* -------------------------------------------------------------------- panel */

type Layout = {
  drivers: number;
  bar: boolean;
  detail: boolean;
  status: boolean;
  /** No blank lines and fewer causes, for a terminal too short for the full pane. */
  tight?: boolean;
  causes?: number;
};

const MAX_DRIVERS = 6;
const MIN_DRIVERS = 2;

/**
 * Richest first: rows are shaved before the bar, the bar before the cause
 * detail, the detail before the status line. The causes never leave.
 */
const LADDER: Layout[] = (() => {
  const out: Layout[] = [];
  const counts = Array.from({ length: MAX_DRIVERS - MIN_DRIVERS + 1 }, (_, i) => MAX_DRIVERS - i);
  for (const bar of [true, false])
    for (const detail of [true, false])
      for (const status of [true, false])
        for (const drivers of counts) out.push({ drivers, bar, detail, status });
  // Below the full pane: blank lines go first, then the causes thin out. Never the headline.
  out.push(
    { drivers: 3, bar: false, detail: false, status: false, tight: true, causes: 3 },
    { drivers: 2, bar: false, detail: false, status: false, tight: true, causes: 2 },
    { drivers: 1, bar: false, detail: false, status: false, tight: true, causes: 1 },
  );
  return out;
})();

const draw = (view: View, theme: Theme, width: number, layout: Layout): Lines => {
  const dim = (text: string) => theme.fg("dim", text);
  const drivers = driverList(view);
  const total = view.breakdown.total;
  const gap = layout.tight ? [] : [""];
  const lines: Lines = [...gap, headline(view, theme), ...gap];
  if (drivers.length === 0) {
    lines.push(dim("  no priced request yet"));
    const status = layout.status ? statusLine(view, theme, width) : [];
    if (status.length > 0) lines.push("", ...status);
    return lines;
  }
  lines.push(heading(theme, "Why it costs this much"));

  const detail = layout.detail && width >= 66;
  const barW = width >= 76 ? 12 : width >= 56 ? 8 : 0;
  const pctW = width >= 64 ? 5 : 0;
  const shown = drivers.slice(0, layout.drivers);
  // The name column fits the longest shown name, so the bars start at one edge.
  const nameW = Math.min(20, Math.max(12, Math.max(...shown.map((d) => d.label.length)) + 2));
  // Where the money column ends, and the label column that puts the causes' money there too.
  const moneyAt = 2 + nameW + (barW > 0 ? barW + 1 : 0) + 9;
  const causeLabelW = Math.max(12, moneyAt - 13);
  const hidden = drivers.slice(layout.drivers);
  for (const d of shown) {
    const part = total > 0 ? d.usd / total : 0;
    const lead =
      `  ${theme.fg(d.color, left(d.label, nameW))}` +
      (barW > 0 ? ` ${theme.fg(d.color, barText(part, barW))}` : "") +
      theme.fg("text", right(formatCost(d.usd), 9)) +
      (pctW > 0 ? dim(right(pctText(part), pctW)) : "");
    const facts = detail && d.cause ? [dim(`  ${d.cause}`)] : [];
    lines.push(...besideOrUnder(lead, facts, width, "  ", 20));
  }
  const folded = hidden.length > 0 ? hidden.reduce((sum, d) => sum + d.usd, 0) : 0;
  // Rows too small to name are already in the bar; only a real remainder gets a line.
  if (hidden.length > 0 && (hidden.length > 1 || folded >= total * 0.01)) {
    lines.push(
      `  ${dim(left(`${hidden.length} more`, nameW))}` +
        (barW > 0 ? " ".repeat(barW + 1) : "") +
        theme.fg("dim", right(formatCost(folded), 9)) +
        (pctW > 0 ? dim(right(pctText(total > 0 ? folded / total : 0), pctW)) : ""),
    );
  }

  if (layout.bar) {
    // Two columns of padding on the right, as on the left, so the panel reads symmetric.
    lines.push("", stackedBar(theme, drivers, width - 2));
  }

  lines.push(...gap, heading(theme, "What you could change"));
  lines.push(...causeLines(view, theme, width, detail, layout.causes ?? 3, causeLabelW));

  if (layout.status) {
    const status = statusLine(view, theme, width);
    if (status.length > 0) lines.push("", ...status);
  }
  return lines;
};

/** Pane 1, in the richest layout that fits `room` lines without scrolling. */
export const verdict = (view: View, theme: Theme, width: number, room: number): Lines => {
  for (const layout of LADDER) {
    const lines = draw(view, theme, width, layout);
    if (lines.length <= room) return lines;
  }
  return draw(view, theme, width, LADDER[LADDER.length - 1]!);
};
