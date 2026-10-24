/**
 * Pane 3: who pays, and how much room is left. The verdict pane shows the plan
 * as one status line; this is where the windows, their pace, the reset times and
 * the prepaid balances are spelled out.
 */
import type { Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import {
  formatCost,
  formatCredit,
  formatSpan,
  formatTokens,
  formatWhen,
} from "../chrome/format.ts";
import { besideOrUnder, gauge, heading, left, right, type Lines, usageColor } from "./draw.ts";
import type { Billing, ProviderView, View } from "./view.ts";

const BILLING_COLOR: Record<Billing, ThemeColor> = {
  credit: "warning",
  "pay-as-you-go": "warning",
  subscription: "success",
  free: "success",
};

/** What a provider's list price means for the money that actually moved. */
const billed = (p: ProviderView) =>
  p.billing === "credit"
    ? `${formatCost(p.usd)} from credit`
    : p.billing === "pay-as-you-go"
      ? "billed"
      : "nothing billed";

const amount = (p: ProviderView) =>
  p.billing === "free" ? `${formatTokens(p.tokens)} tokens` : `${formatCost(p.usd)} list`;

const PACE: Record<"under" | "over" | "exhausted", { text: string; color: ThemeColor }> = {
  under: { text: "under pace", color: "dim" },
  over: { text: "over pace", color: "warning" },
  exhausted: { text: "exhausted", color: "error" },
};

/** One window: the gauge, then its percentage, growth, pace and when it resets. */
const windowLines = (p: ProviderView, theme: Theme, width: number): Lines => {
  const dim = (text: string) => theme.fg("dim", text);
  const windows = p.windows ?? [];
  if (windows.length === 0) return [];
  const labelW = Math.min(12, Math.max(...windows.map((w) => w.label.length)) + 2);
  const lines: Lines = [];
  for (const w of windows) {
    const facts = [
      `${theme.fg(usageColor(w.usedPct), `${Math.round(w.usedPct)}%`)}`,
      w.delta >= 1 ? theme.fg("warning", `+${Math.round(w.delta)}`) : "",
      w.pace && w.pace !== "under" ? theme.fg(PACE[w.pace].color, PACE[w.pace].text) : "",
      w.resetsAt ? dim(`resets ${formatWhen(new Date(w.resetsAt))}`) : "",
    ].filter(Boolean);
    lines.push(
      ...besideOrUnder(
        `    ${dim(left(w.label, labelW))} ${gauge(theme, w.usedPct / 100, 10, usageColor(w.usedPct))} `,
        facts,
        width,
        dim(" · "),
        12,
      ),
    );
  }
  return lines;
};

const creditLines = (p: ProviderView, theme: Theme, width: number): Lines => {
  if (!p.credit) return [];
  const dim = (text: string) => theme.fg("dim", text);
  const { remaining, allowance, runsOutAt } = p.credit;
  const left_ = allowance > 0 ? remaining / allowance : 0;
  const facts = [runsOutAt ? dim(`empty ${formatWhen(new Date(runsOutAt))}`) : ""].filter(Boolean);
  const color = left_ <= 0.05 ? "error" : left_ <= 0.2 ? "warning" : "success";
  return besideOrUnder(
    `    ${theme.fg(color, formatCredit(remaining))}` +
      theme.fg("dim", ` of ${formatCredit(allowance)} left `) +
      gauge(theme, left_, 10, color) +
      "  ",
    facts,
    width,
    " · ",
    12,
  );
};

export const quota = (view: View, theme: Theme, width: number): Lines => {
  const dim = (text: string) => theme.fg("dim", text);
  if (view.providers.length === 0) {
    return ["", heading(theme, "Billing"), dim("  no provider has priced this session")];
  }
  const lines: Lines = ["", heading(theme, "Billing")];
  const idW = Math.min(14, Math.max(...view.providers.map((p) => p.id.length)) + 2);
  for (const p of view.providers) {
    // A provider this session never touched has a billing mode and a balance to show, no charge.
    const spent = p.usd >= 0.005;
    lines.push(
      `  ${theme.fg("text", left(p.id, idW))}${theme.fg(BILLING_COLOR[p.billing], left(p.billing, 14))}` +
        (spent ? `${theme.fg("text", right(amount(p), 14))}  ${dim(billed(p))}` : ""),
    );
    lines.push(...windowLines(p, theme, width), ...creditLines(p, theme, width));
  }

  // A plan's quota is shared, so growth counts sessions this panel never saw.
  const grew = view.providers.some((p) => (p.windows ?? []).some((w) => w.delta >= 1));
  const elapsed = Math.max(0, Date.now() - view.openedAt.getTime());
  const total = view.providers.reduce((sum, p) => sum + p.usd, 0);
  const burn = elapsed > 0 ? total / (elapsed / 3_600_000) : 0;
  lines.push(
    "",
    `  ${dim("burn")} ${theme.fg("text", `${formatCost(burn)}/h`)} ` +
      dim(`at list price, ${formatSpan(elapsed)} in`),
  );
  // A plan's quota is shared with sessions this panel never saw.
  if (grew) lines.push(dim(`  +N is growth since ${formatWhen(view.openedAt)}, all sessions`));
  return lines;
};
