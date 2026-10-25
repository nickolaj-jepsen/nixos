/**
 * The one pane: what the session cost and who paid, the quota left in each
 * pool, where the money went by feature and role, and the costliest turns.
 */
import type { Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { formatCost, formatCredit, formatTokens, formatWhen } from "../lib/format.ts";
import type { UsageWindow } from "../../shared/ai-usage.ts";
import type { RowKind, Turn } from "./breakdown.ts";
import { type Billing, billed, onPlans, type View } from "./view.ts";

type Lines = string[];

const ROWS_SHOWN = 8;
const TURNS_SHOWN = 5;
// One thing has to carry this share of a turn's cost to be named as its cause.
const CAUSE_SHARE = 0.3;

const BILLING: Record<Billing, { text: string; color: ThemeColor }> = {
  credit: { text: "billed, from credit", color: "warning" },
  "pay-as-you-go": { text: "billed", color: "warning" },
  subscription: { text: "on plan, at list price", color: "success" },
  free: { text: "free", color: "dim" },
};

const TAG: Record<RowKind, string> = {
  loop: "",
  child: "subagent",
  side: "side call",
  tool: "tool fee",
};

const PACE: Record<UsageWindow["pace"], { text: string; color: ThemeColor }> = {
  under: { text: "under pace", color: "dim" },
  over: { text: "over pace", color: "warning" },
  exhausted: { text: "exhausted", color: "error" },
};

const right = (text: string, width: number) =>
  " ".repeat(Math.max(0, width - visibleWidth(text))) + text;

const left = (text: string, width: number) => truncateToWidth(text, width, "…", true);

const pctText = (fraction: number) => {
  const pct = fraction * 100;
  return pct > 0 && pct < 1 ? "<1%" : `${Math.round(pct)}%`;
};

const usageColor = (pct: number): ThemeColor =>
  pct >= 90 ? "error" : pct >= 60 ? "warning" : "success";

/** A quota gauge: the used part in `color`, the rest a `░` track. */
const gauge = (theme: Theme, fraction: number, cells: number, color: ThemeColor) => {
  const filled = Math.round(Math.max(0, Math.min(1, fraction)) * cells);
  return theme.fg(color, "━".repeat(filled)) + theme.fg("borderMuted", "░".repeat(cells - filled));
};

const heading = (theme: Theme, title: string) => theme.fg("accent", theme.bold(title));

const headline = (view: View, theme: Theme) => {
  const paid = billed(view.providers);
  const plan = onPlans(view.providers);
  // Under half a cent is not a charge worth naming.
  const facts = [
    paid >= 0.005 ? `${formatCost(paid)} billed` : "nothing billed",
    plan >= 0.005 ? `${formatCost(plan)} on plan` : "",
  ].filter(Boolean);
  return (
    theme.bold(theme.fg("text", formatCost(view.breakdown.total))) +
    theme.fg("dim", `  ${facts.join(" · ")}`)
  );
};

const providerLines = (view: View, theme: Theme, idW: number): Lines =>
  view.providers.map((p) => {
    const billing = BILLING[p.billing];
    const amount = p.billing === "free" ? `${formatTokens(p.tokens)} tok` : formatCost(p.usd);
    return (
      `  ${theme.fg("text", left(p.id, idW))}${theme.fg("text", right(amount, 9))}  ` +
      theme.fg(billing.color, billing.text)
    );
  });

const poolLines = (view: View, theme: Theme, width: number, idW: number, now: Date): Lines => {
  const dim = (text: string) => theme.fg("dim", text);
  return view.pools.map(({ id, window: w, credit }) => {
    const color = usageColor(w.usedPct);
    const pace = PACE[w.pace];
    const when = formatWhen(new Date(w.resetsAt), now);
    const facts = [
      credit ? theme.fg(color, `${formatCredit(credit.remaining)} left`) : "",
      theme.fg(pace.color, pace.text),
      dim(`${w.meter ? "tops up" : "resets"} ${when}`),
    ].filter(Boolean);
    const line =
      `  ${theme.fg("text", left(id, idW))}${dim(left(w.label, 7))}` +
      `${gauge(theme, w.usedPct / 100, 10, color)}${theme.fg(color, right(`${Math.round(w.usedPct)}%`, 5))}  ` +
      facts.join(dim(" · "));
    return truncateToWidth(line, width, "…");
  });
};

const rowLines = (view: View, theme: Theme, width: number): Lines => {
  const dim = (text: string) => theme.fg("dim", text);
  const { rows, total } = view.breakdown;
  const nameW = Math.max(8, width - 2 - 7 - 9 - 6);
  const line = (name: string, calls: string, usd: number, color: ThemeColor) =>
    `  ${left(name, nameW)}` +
    dim(right(calls, 7)) +
    theme.fg(color, right(formatCost(usd), 9)) +
    dim(right(pctText(total > 0 ? usd / total : 0), 6));
  // Folding a single row would only rename it.
  const shown = rows.length > ROWS_SHOWN ? rows.slice(0, ROWS_SHOWN - 1) : rows;
  const rest = rows.slice(shown.length);
  const lines = shown.map((row) =>
    line(
      theme.fg("text", row.name) + (TAG[row.kind] ? dim(` · ${TAG[row.kind]}`) : ""),
      `${row.calls}×`,
      row.usd,
      "text",
    ),
  );
  if (rest.length > 0) {
    const usd = rest.reduce((sum, row) => sum + row.usd, 0);
    lines.push(line(dim(`${rest.length} more`), "", usd, "dim"));
  }
  return lines;
};

/** The one thing that made a turn cost what it did. */
const cause = (turn: Turn): { text: string; color: ThemeColor } => {
  if (turn.rebuilds > 0 && turn.rebuildUsd >= turn.usd * CAUSE_SHARE) {
    const n = turn.rebuilds;
    return { text: `${n} cache rebuild${n === 1 ? "" : "s"}`, color: "warning" };
  }
  const driver = turn.driver;
  if (driver && (driver.usd >= turn.usd * CAUSE_SHARE || turn.replies === 0)) {
    return { text: `${driver.name} ×${driver.calls}`, color: "muted" };
  }
  const n = turn.replies;
  return { text: `${n} repl${n === 1 ? "y" : "ies"}`, color: "dim" };
};

const turnLines = (view: View, theme: Theme, width: number): Lines => {
  const top = view.breakdown.turns
    .filter((turn) => turn.usd > 0)
    .sort((a, b) => b.usd - a.usd)
    .slice(0, TURNS_SHOWN);
  return top.map((turn) => {
    const badge = cause(turn);
    const badgeText = truncateToWidth(badge.text, Math.max(8, Math.floor(width / 3)), "…");
    const lead = `  ${theme.fg("text", right(formatCost(turn.usd), 7))}  `;
    const room = width - visibleWidth(lead) - visibleWidth(badgeText) - 2;
    const text = truncateToWidth(turn.text || "(no text)", Math.max(4, room), "…");
    return (
      lead +
      theme.fg("muted", left(text, Math.max(4, room))) +
      "  " +
      theme.fg(badge.color, badgeText)
    );
  });
};

export const pane = (view: View, theme: Theme, width: number, now = new Date()): Lines => {
  const ids = [...view.providers.map((p) => p.id), ...view.pools.map((p) => p.id)];
  const idW = Math.min(16, Math.max(8, ...ids.map((id) => visibleWidth(id))) + 2);
  const lines: Lines = ["", headline(view, theme), ...providerLines(view, theme, idW)];
  if (view.pools.length > 0) {
    lines.push("", heading(theme, "Quota"), ...poolLines(view, theme, width, idW, now));
  }
  if (view.breakdown.rows.length === 0) {
    lines.push("", theme.fg("dim", "  no priced request yet"));
    return lines;
  }
  lines.push("", heading(theme, "Where it went"), ...rowLines(view, theme, width));
  const turns = turnLines(view, theme, width);
  if (turns.length > 0) lines.push("", heading(theme, "Costliest turns"), ...turns);
  return lines;
};
