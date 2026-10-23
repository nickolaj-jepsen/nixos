import type { Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import {
  Key,
  matchesKey,
  truncateToWidth,
  visibleWidth,
  type Component,
  type TUI,
} from "@earendil-works/pi-tui";
import { formatCost, formatCredit, formatTokens, formatWhen } from "../chrome/format.ts";
import type { ItemKind } from "../lib/usage-ledger.ts";
import type { Breakdown, Prompt, Row } from "./breakdown.ts";
import {
  type ContextSource,
  type Rebuild,
  type RebuildCause,
  SYSTEM_SOURCE,
  type ThinkingLevelView,
} from "./insights.ts";

/**
 * Who pays for a provider's tokens. `subscription` spend is the catalog price
 * of what a flat plan covered, not money; `credit` draws down a prepaid grant.
 */
export type Billing = "credit" | "subscription" | "free" | "pay-as-you-go";

export type ProviderView = {
  id: string;
  usd: number;
  tokens: number;
  billing: Billing;
  /** A prepaid balance, from ai-usage. */
  credit?: { remaining: number; allowance: number; runsOutAt?: string };
  /** A plan's quota windows, from ai-usage; `delta` is the growth since the session opened. */
  windows?: Array<{ label: string; usedPct: number; delta: number }>;
};

export type View = {
  breakdown: Breakdown;
  providers: ProviderView[];
  /** When the quota baseline was taken; window growth counts from here. */
  openedAt: Date;
  rebuilds: Rebuild[];
  thinking: ThinkingLevelView[];
  /** What the current branch's requests re-sent, by source. */
  context: ContextSource[];
  /** The context's size now, when pi knows it. */
  contextTokens?: number;
  modelName: (provider: string, model: string) => string;
};

type Lines = string[];

/* ------------------------------------------------------------------ drawing */

const EIGHTHS = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"];
const clamp = (n: number) => Math.max(0, Math.min(1, Number.isFinite(n) ? n : 0));

/** A bar `cells` wide filled to `fraction`, in eighths; unpainted, padded with spaces. */
const barText = (fraction: number, cells: number) => {
  const units = Math.round(clamp(fraction) * cells * 8);
  const text = "█".repeat(Math.floor(units / 8)) + EIGHTHS[units % 8];
  return text + " ".repeat(Math.max(0, cells - visibleWidth(text)));
};

/** A gauge: the filled part in `color`, the rest a faint track. */
const gauge = (theme: Theme, fraction: number, cells: number, color: ThemeColor) => {
  const filled = Math.round(clamp(fraction) * cells);
  return theme.fg(color, "━".repeat(filled)) + theme.fg("borderMuted", "━".repeat(cells - filled));
};

const right = (text: string, width: number) =>
  " ".repeat(Math.max(0, width - visibleWidth(text))) + text;

const left = (text: string, width: number) =>
  truncateToWidth(text, width, "…") + " ".repeat(Math.max(0, width - visibleWidth(text)));

const heading = (theme: Theme, title: string, note = "") =>
  theme.fg("accent", theme.bold(title)) + (note ? theme.fg("dim", `  ${note}`) : "");

/** Joins `items` with `sep`, wrapping onto new lines rather than cutting one off. */
const flow = (items: readonly string[], width: number, sep: string, indent = ""): Lines => {
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
const MIN_FACTS_W = 34;
const UNDER_INDENT = "      ";

/** `lead` followed by `facts`, wrapped beside it, or under it when the line is too narrow. */
const besideOrUnder = (lead: string, facts: readonly string[], width: number, sep: string) => {
  const room = width - visibleWidth(lead);
  if (room >= MIN_FACTS_W) {
    const wrapped = flow(facts, room, sep);
    return [
      lead + (wrapped[0] ?? ""),
      ...wrapped.slice(1).map((more) => " ".repeat(visibleWidth(lead)) + more),
    ];
  }
  return [lead, ...flow(facts, width, sep, UNDER_INDENT)];
};

const usageColor = (pct: number): ThemeColor =>
  pct >= 90 ? "error" : pct >= 60 ? "warning" : "success";

/* ----------------------------------------------------------------- insights */

const LEVELS = " ▁▂▃▄▅▆▇";
const CHART_ROWS = 3;
// A bucket whose spend went this much on cache rebuilds is drawn as one.
const REBUILD_SHARE = 0.3;
const PROMPTS_SHOWN = 3;

/**
 * Spend per prompt as a chart `CHART_ROWS` tall across the full width, oldest
 * left. Prompts share columns when there are more than columns, and widen to
 * fill the row when there are fewer.
 */
const spendChart = (theme: Theme, timeline: readonly Prompt[], width: number): Lines => {
  const prompts = timeline.filter((p) => p.usd > 0);
  if (prompts.length < 2) return [];
  const buckets = Array.from({ length: width }, () => ({ usd: 0, rebuild: 0 }));
  if (prompts.length >= width) {
    prompts.forEach((p, i) => {
      const bucket = buckets[Math.floor((i / prompts.length) * width)]!;
      bucket.usd += p.usd;
      bucket.rebuild += p.rebuildUsd;
    });
  } else {
    buckets.forEach((bucket, column) => {
      const p = prompts[Math.floor((column / width) * prompts.length)]!;
      bucket.usd = p.usd;
      bucket.rebuild = p.rebuildUsd;
    });
  }
  const peak = Math.max(...buckets.map((b) => b.usd));
  const heights = buckets.map((b) => Math.max(1, Math.round((b.usd / peak) * CHART_ROWS * 8)));
  const lines: Lines = [];
  for (let row = CHART_ROWS - 1; row >= 0; row--) {
    lines.push(
      buckets
        .map((b, i) => {
          const h = heights[i]! - row * 8;
          const glyph = h >= 8 ? "█" : h > 0 ? LEVELS[h]! : " ";
          return theme.fg(b.rebuild >= b.usd * REBUILD_SHARE ? "warning" : "muted", glyph);
        })
        .join(""),
    );
  }
  const rebuilt = prompts.some((p) => p.rebuildUsd >= p.usd * REBUILD_SHARE);
  lines.push(
    theme.fg(
      "dim",
      `spend per prompt · ${prompts.length} prompts, oldest left · peak ${formatCost(peak)}`,
    ) + (rebuilt ? theme.fg("warning", " · █ mostly cache rebuild") : ""),
  );
  return lines;
};

const CAUSE_TEXT: Record<RebuildCause, string> = {
  idle: "idle past the cache lifetime",
  "model switch": "model switch",
  "prefix changed": "prompt prefix changed",
};

/** Rebuilds by cause, costliest first; a line saying so when there were none. */
const rebuildLines = (theme: Theme, rebuilds: readonly Rebuild[], width: number): Lines => {
  if (rebuilds.length === 0) return [theme.fg("dim", "  no cache rebuilds")];
  const total = rebuilds.reduce((s, r) => s + r.usd, 0);
  const causes = new Map<RebuildCause, { n: number; usd: number; gap: number }>();
  for (const r of rebuilds) {
    const c = causes.get(r.cause) ?? { n: 0, usd: 0, gap: 0 };
    c.n += 1;
    c.usd += r.usd;
    c.gap = Math.max(c.gap, r.gap);
    causes.set(r.cause, c);
  }
  const facts = [...causes]
    .sort((a, b) => b[1].usd - a[1].usd)
    .map(
      ([cause, c]) =>
        `${c.n}× ${CAUSE_TEXT[cause]} ${formatCost(c.usd)}` +
        (cause === "idle" ? theme.fg("dim", ` (longest ${Math.round(c.gap / 60)}m)`) : ""),
    );
  return besideOrUnder(
    `  ${theme.fg("warning", `${rebuilds.length} rebuild${rebuilds.length === 1 ? "" : "s"}, ${formatCost(total)}`)}  `,
    facts,
    width,
    theme.fg("dim", " · "),
  );
};

const thinkingLines = (
  theme: Theme,
  levels: readonly ThinkingLevelView[],
  width: number,
): Lines => {
  if (levels.length === 0) return [];
  const dim = (text: string) => theme.fg("dim", text);
  const lines: Lines = ["", heading(theme, "Thinking", "reasoning is billed as output")];
  for (const l of levels) {
    const lead = `  ${left(l.level, 9)}${dim(right(`${l.replies}×`, 6))}  `;
    if (l.reasoning === undefined) {
      lines.push(lead + dim(`reasoning not reported · output ${formatCost(l.outputUsd)}`));
      continue;
    }
    const share = l.output > 0 ? l.reasoning / l.output : 0;
    lines.push(
      ...besideOrUnder(
        lead,
        [
          `${gauge(theme, share, 10, "syntaxVariable")} ${right(pctText(share), 4)} of output`,
          `${formatCost(l.reasoningUsd)} of ${formatCost(l.outputUsd)}`,
          dim(`≈${formatTokens(Math.round(l.reasoning / l.replies))}/reply`),
        ],
        width,
        dim(" · "),
      ),
    );
  }
  return lines;
};

const CONTEXT_COLORS: ThemeColor[] = [
  "mdLink",
  "success",
  "warning",
  "syntaxVariable",
  "accent",
  "error",
];
const CONTEXT_SHOWN = 6;

/** The context by source: a bar of what is in it now, and what re-sending each cost. */
const contextLines = (view: View, theme: Theme, width: number): Lines => {
  const sources = view.context;
  if (sources.length === 0) return [];
  const dim = (text: string) => theme.fg("dim", text);
  const shown = sources.slice(0, CONTEXT_SHOWN);
  const rest = sources.slice(CONTEXT_SHOWN);
  const rows = rest.length
    ? [
        ...shown,
        {
          name: `${rest.length} more`,
          now: rest.reduce((s, r) => s + r.now, 0),
          usd: rest.reduce((s, r) => s + r.usd, 0),
        },
      ]
    : shown;
  let hue = 0;
  const colored = rows.map((r, i) => ({
    ...r,
    color: (r.name === SYSTEM_SOURCE
      ? "muted"
      : i === CONTEXT_SHOWN
        ? "dim"
        : (CONTEXT_COLORS[hue++ % CONTEXT_COLORS.length] ?? "dim")) as ThemeColor,
  }));
  const now = view.contextTokens ?? colored.reduce((s, r) => s + r.now, 0);
  const spent = colored.reduce((s, r) => s + r.usd, 0);

  const lines: Lines = [
    "",
    heading(
      theme,
      "Context",
      `≈${formatTokens(now)} now · re-sent with every request, this branch`,
    ),
    stackedBar(
      theme,
      colored.map((r) => ({ label: r.name, usd: r.now, color: r.color })),
      width,
    ),
  ];
  const nameW = 18;
  const barW = Math.max(0, width - 2 - nameW - 8 - 9 - 6 - 2);
  lines.push(dim(`  ${" ".repeat(nameW)}${right("now", 8)}  ${left("re-send cost", barW)}`));
  for (const r of colored) {
    const share = spent > 0 ? r.usd / spent : 0;
    lines.push(
      `  ${theme.fg(r.color, "■")} ${left(r.name, nameW - 2)}` +
        dim(right(r.now > 0 ? formatTokens(r.now) : "·", 8)) +
        "  " +
        (barW >= 6 ? theme.fg("muted", barText(share, barW)) : "") +
        right(formatCost(r.usd), 9) +
        dim(right(pctText(share), 6)),
    );
  }
  return lines;
};

/* ----------------------------------------------------------------- overview */

/** What the money bought, across every row; each slice has a color of its own. */
type Slice = { label: string; usd: number; color: ThemeColor };

const slices = (breakdown: Breakdown): Slice[] => {
  let input = 0;
  let read = 0;
  let write = 0;
  let longWrite = 0;
  let output = 0;
  let tools = 0;
  for (const row of breakdown.rows) {
    const c = row.usage.cost;
    if (row.kind === "tool") {
      tools += c.total;
      continue;
    }
    input += c.input;
    read += c.cacheRead;
    output += c.output;
    // Without a catalog price the 1h share can't be told apart from the 5m one.
    const long = Math.min(row.longWrite?.usd ?? 0, c.cacheWrite);
    longWrite += long;
    write += c.cacheWrite - long;
  }
  const parts: Slice[] = [
    { label: "input", usd: input, color: "mdLink" },
    { label: "cache read", usd: read, color: "success" },
    { label: "cache write 5m", usd: write, color: "warning" },
    { label: "cache write 1h", usd: longWrite, color: "error" },
    { label: "output", usd: output, color: "syntaxVariable" },
    { label: "tools", usd: tools, color: "muted" },
  ];
  // Rows whose components don't add up to their total (tiered or flat pricing).
  const other = breakdown.total - parts.reduce((sum, p) => sum + p.usd, 0);
  if (other > breakdown.total * 0.005) parts.push({ label: "other", usd: other, color: "dim" });
  return parts.filter((p) => p.usd > 0.00005);
};

/** One full-width bar split by slice, cells shared out by largest remainder. */
const stackedBar = (theme: Theme, parts: readonly Slice[], cells: number) => {
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

const KIND_TAG: Record<ItemKind, string> = {
  conversation: "chat",
  upkeep: "upkeep",
  side: "side",
  tool: "tool",
};

const rowName = (view: View, row: Row) => {
  const model = row.provider && row.model ? view.modelName(row.provider, row.model) : undefined;
  if (row.kind === "conversation") return model ?? row.name;
  return model ? `${row.name} · ${model}` : row.name;
};

const pctText = (fraction: number) => {
  const pct = fraction * 100;
  return pct > 0 && pct < 1 ? "<1%" : `${Math.round(pct)}%`;
};

const overview = (view: View, theme: Theme, width: number): Lines => {
  const { breakdown } = view;
  const dim = (text: string) => theme.fg("dim", text);
  const lines: Lines = [];
  const total = breakdown.total;

  // Headline: the total, and how much of it is money rather than plan usage.
  const paid = view.providers
    .filter((p) => p.billing === "credit" || p.billing === "pay-as-you-go")
    .reduce((s, p) => s + p.usd, 0);
  const plan = view.providers
    .filter((p) => p.billing === "subscription")
    .reduce((s, p) => s + p.usd, 0);
  const tools = breakdown.rows
    .filter((r) => r.kind === "tool")
    .reduce((s, r) => s + r.usage.cost.total, 0);
  const summary = [
    paid > 0 ? theme.fg("warning", `${formatCost(paid)} billed`) : "",
    plan > 0 ? theme.fg("success", `${formatCost(plan)} on plans`) : "",
    tools > 0 ? theme.fg("muted", `${formatCost(tools)} tools`) : "",
  ].filter(Boolean);
  const head = `${theme.bold(theme.fg("text", formatCost(total)))}${dim("  this session")}`;
  const tail = summary.join(dim(" · "));
  const gap = width - visibleWidth(head) - visibleWidth(tail);
  lines.push(gap >= 2 ? head + " ".repeat(gap) + tail : head);
  if (gap < 2 && tail) lines.push(tail);

  const parts = slices(breakdown);
  lines.push(stackedBar(theme, parts, width));
  lines.push(
    ...flow(
      parts.map((p) => `${theme.fg(p.color, "■")} ${dim(p.label)} ${formatCost(p.usd)}`),
      width,
      "   ",
    ),
  );
  const chart = spendChart(theme, breakdown.timeline, width);
  if (chart.length > 0) lines.push("", ...chart);

  // Where it went: every row ranked, with its share of the total.
  const rows = breakdown.rows.filter((r) => r.usage.cost.total > 0.00005);
  if (rows.length > 0) {
    lines.push("", heading(theme, "Where it went"));
    const nameW = Math.min(36, Math.max(12, Math.floor(width * 0.34)));
    const tagW = 8;
    const callsW = 9;
    const costW = 9;
    const pctW = 5;
    const barW = Math.max(0, width - 2 - nameW - tagW - callsW - costW - pctW - 3);
    for (const row of rows) {
      const share = total > 0 ? row.usage.cost.total / total : 0;
      // Failed replies may still have been billed, so they stay in the count, flagged.
      const failed = row.failed > 0 ? ` ${row.failed}✗` : "";
      const calls =
        " ".repeat(Math.max(0, callsW - visibleWidth(`${row.calls}×${failed}`))) +
        dim(`${row.calls}×`) +
        theme.fg("error", failed);
      lines.push(
        `  ${left(rowName(view, row), nameW - 1)} ` +
          dim(left(KIND_TAG[row.kind], tagW)) +
          calls +
          (barW >= 6 ? ` ${theme.fg("muted", barText(share, barW))}` : "") +
          right(formatCost(row.usage.cost.total), costW) +
          dim(right(pctText(share), pctW + 1)),
      );
    }
    const free = breakdown.rows.filter((r) => r.usage.cost.total <= 0.00005);
    if (free.length > 0) {
      lines.push(dim(`  + ${free.map((r) => rowName(view, r)).join(", ")} at no cost`));
    }
  }

  // Cache: how well the prompt cache worked, and what the 1h tier cost on top.
  const cached = breakdown.rows.filter(
    (r) => r.kind === "conversation" && r.usage.input + r.usage.cacheRead + r.usage.cacheWrite > 0,
  );
  if (cached.length > 0) {
    lines.push("", heading(theme, "Cache"));
    const nameW = Math.min(36, Math.max(12, Math.floor(width * 0.34)));
    for (const row of cached) {
      const u = row.usage;
      const hit = u.cacheRead / (u.input + u.cacheRead + u.cacheWrite);
      const facts = [
        `${gauge(theme, hit, 12, hit >= 0.9 ? "success" : hit >= 0.5 ? "warning" : "error")} ${right(pctText(hit), 4)} hit`,
        row.saved !== undefined && row.saved >= 0.005
          ? `saved ${theme.fg("success", `≈${formatCost(row.saved)}`)}`
          : "",
        u.cacheWrite > 0 ? dim(`wrote ${formatTokens(u.cacheWrite)}`) : "",
        (u.cacheWrite1h ?? 0) > 0
          ? theme.fg(
              "error",
              `1h writes ${formatTokens(u.cacheWrite1h ?? 0)}` +
                (row.longWrite
                  ? `: ${formatCost(row.longWrite.usd)}, +${formatCost(row.longWrite.premium)} over 5m`
                  : ""),
            )
          : "",
      ].filter(Boolean);
      lines.push(
        ...besideOrUnder(`  ${left(rowName(view, row), nameW - 1)} `, facts, width, dim(" · ")),
      );
    }
    lines.push(...rebuildLines(theme, view.rebuilds, width));
  }

  lines.push(...thinkingLines(theme, view.thinking, width));
  lines.push(...contextLines(view, theme, width));

  // Billing: whose money or quota each provider drew on.
  if (view.providers.length > 0) {
    lines.push("", heading(theme, "Billing"));
    const idW = Math.min(14, Math.max(...view.providers.map((p) => visibleWidth(p.id))) + 2);
    const BILLING_COLOR: Record<Billing, ThemeColor> = {
      credit: "warning",
      "pay-as-you-go": "warning",
      subscription: "success",
      free: "success",
    };
    let grew = false;
    for (const p of view.providers) {
      const amount =
        p.billing === "free"
          ? `${formatTokens(p.tokens)} tok`
          : p.billing === "subscription"
            ? `${formatCost(p.usd)} list`
            : formatCost(p.usd);
      const facts: string[] = [];
      if (p.credit) {
        const { remaining, allowance, runsOutAt } = p.credit;
        const left = allowance > 0 ? remaining / allowance : 0;
        facts.push(
          `${gauge(theme, left, 10, left <= 0.05 ? "error" : left <= 0.2 ? "warning" : "success")} ` +
            `${formatCredit(remaining)}${dim(` of ${formatCredit(allowance)} left`)}`,
        );
        if (runsOutAt) facts.push(dim(`empty ${formatWhen(new Date(runsOutAt))}`));
      }
      for (const w of p.windows ?? []) {
        const delta = Math.round(w.delta);
        if (delta > 0) grew = true;
        facts.push(
          `${dim(w.label)} ${gauge(theme, w.usedPct / 100, 8, usageColor(w.usedPct))} ` +
            `${Math.round(w.usedPct)}%${delta > 0 ? theme.fg("warning", ` +${delta}`) : ""}`,
        );
      }
      const lead =
        `  ${left(p.id, idW)}` +
        theme.fg(BILLING_COLOR[p.billing], left(p.billing, 14)) +
        right(amount, 11) +
        "   ";
      lines.push(...besideOrUnder(lead, facts, width, "   "));
    }
    // A plan's quota is shared, so the growth counts every session on it.
    if (grew) lines.push(dim(`  +N: growth since ${formatWhen(view.openedAt)}, all sessions`));
  }

  const costliest = breakdown.timeline
    .filter((p) => p.usd > 0)
    .sort((a, b) => b.usd - a.usd)
    .slice(0, PROMPTS_SHOWN);
  if (costliest.length > 0) {
    lines.push("", heading(theme, "Costliest prompts"));
    const top = costliest[0]!.usd;
    for (const prompt of costliest) {
      const lead = `  ${right(formatCost(prompt.usd), 7)} ${theme.fg("muted", barText(prompt.usd / top, 8))} `;
      lines.push(
        lead + dim(truncateToWidth(prompt.text || "(empty)", width - visibleWidth(lead), "…")),
      );
    }
  }
  return lines;
};

/* ------------------------------------------------------------------ details */

// Width of each number column, its gap included.
const CALLS_W = 10;
const TOKENS_W = 9;
const COST_W = 10;
// Below this the token columns go; calls and cost stay.
const WIDE = 78;

const SECTIONS: ReadonlyArray<readonly [ItemKind, string]> = [
  ["conversation", "Conversation"],
  ["upkeep", "Upkeep"],
  ["side", "Side calls"],
  ["tool", "Tools"],
];

/** Every row with its tokens and cost split, for when the overview raises a question. */
const details = (view: View, theme: Theme, width: number): Lines => {
  const wide = width >= WIDE;
  const nameW = Math.max(8, width - CALLS_W - (wide ? TOKENS_W * 4 : 0) - COST_W);
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
  const tok = (n: number) => (n === 0 ? "·" : formatTokens(Math.round(n)));

  for (const [kind, title] of SECTIONS) {
    const rows = view.breakdown.rows.filter((row) => row.kind === kind);
    if (rows.length === 0) continue;
    if (lines.length > 0) lines.push("");
    lines.push(left(heading(theme, title), nameW) + dim(header));
    for (const row of rows) {
      const u = row.usage;
      lines.push(
        `  ${left(rowName(view, row), nameW - 2)}` +
          right(`${row.calls}${row.failed > 0 ? ` (${row.failed}✗)` : ""}`, CALLS_W) +
          (wide
            ? right(tok(u.input), TOKENS_W) +
              right(tok(u.cacheRead), TOKENS_W) +
              right(tok(u.cacheWrite), TOKENS_W) +
              right(tok(u.output), TOKENS_W)
            : "") +
          right(formatCost(u.cost.total), COST_W),
      );
      if (row.kind === "tool") continue;
      const split = (
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
        split.push(
          `1h writes ${formatTokens(u.cacheWrite1h ?? 0)} of ${formatTokens(u.cacheWrite)}`,
        );
      }
      if (split.length > 0)
        lines.push(dim(truncateToWidth(`    ${split.join(" · ")}`, width, "…")));
    }
  }
  return lines;
};

/* ------------------------------------------------------------------- dialog */

// Rows kept free around the overlay, so the editor border stays in view.
const MARGIN_ROWS = 4;
const PANEL_BG = "userMessageBg";

/**
 * A rounded panel over the transcript: the overview, or the token table after
 * tab. Esc, enter or q closes it; arrows and page keys scroll.
 */
export class CostDialog implements Component {
  private scroll = 0;
  private showDetails = false;
  private readonly tui: TUI;
  private readonly theme: Theme;
  private readonly view: () => View;
  private readonly done: () => void;

  constructor(tui: TUI, theme: Theme, view: () => View, done: () => void) {
    this.tui = tui;
    this.theme = theme;
    this.view = view;
    this.done = done;
  }

  /** The view changed (a usage refresh, a new entry); redraw it. */
  refresh() {
    this.tui.requestRender();
  }

  invalidate() {}

  handleInput(data: string) {
    if (matchesKey(data, Key.escape) || matchesKey(data, Key.enter) || data === "q") {
      this.done();
      return;
    }
    if (matchesKey(data, Key.tab) || data === "d") {
      this.showDetails = !this.showDetails;
      this.scroll = 0;
      this.tui.requestRender();
      return;
    }
    const step =
      matchesKey(data, Key.up) || data === "k"
        ? -1
        : matchesKey(data, Key.down) || data === "j"
          ? 1
          : matchesKey(data, Key.pageUp)
            ? -10
            : matchesKey(data, Key.pageDown)
              ? 10
              : 0;
    if (step !== 0) {
      this.scroll = Math.max(0, this.scroll + step);
      this.tui.requestRender();
    }
  }

  render(width: number): string[] {
    const theme = this.theme;
    // Two columns of border and two of padding on each side.
    const inner = Math.max(10, width - 6);
    const view = this.view();
    const body = [
      "",
      ...(this.showDetails ? details(view, theme, inner) : overview(view, theme, inner)),
      "",
    ];
    const room = Math.max(3, this.tui.terminal.rows - MARGIN_ROWS - 2);
    this.scroll = Math.min(this.scroll, Math.max(0, body.length - room));
    const shown = body.slice(this.scroll, this.scroll + room);

    // Every reset inside a line would drop the panel background; put it back after each.
    const bg = theme.getBgAnsi(PANEL_BG);
    const onPanel = (line: string) =>
      bg + line.replace(/\x1b\[0?m/g, (reset) => reset + bg).replace(/\x1b\[49m/g, bg) + "\x1b[49m";
    const border = (text: string) => theme.fg("borderMuted", text);
    const pad = (line: string) => truncateToWidth(`  ${line}`, width - 2, "…", true);

    const title = ` ${this.showDetails ? "Session cost · tokens" : "Session cost"} `;
    const more = body.length > room;
    const hints = [
      this.showDetails ? "tab overview" : "tab tokens",
      more ? `↑↓ ${this.scroll + shown.length}/${body.length}` : "",
      "esc close",
    ].filter(Boolean);
    const footer = ` ${hints.join(" · ")} `;
    const topFill = Math.max(0, width - 3 - visibleWidth(title));
    const bottomFill = Math.max(0, width - 3 - visibleWidth(footer));
    return [
      onPanel(
        border("╭─") + theme.fg("accent", theme.bold(title)) + border(`${"─".repeat(topFill)}╮`),
      ),
      ...shown.map((line) => onPanel(border("│") + pad(line) + border("│"))),
      onPanel(border(`╰${"─".repeat(bottomFill)}`) + theme.fg("dim", footer) + border("─╯")),
    ];
  }
}
