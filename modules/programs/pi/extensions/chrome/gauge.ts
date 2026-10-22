import { visibleWidth } from "@earendil-works/pi-tui";
import { formatTokens } from "./format.ts";
import type { ChromeState } from "./state.ts";

const USED = "━";
const FREE = "─";
const WARN_PCT = 60;
const ERROR_PCT = 85;
// Narrower than this the bar stops reading as a gauge, so its text goes first.
const MIN_BAR = 10;

/**
 * The editor's bottom border as a context gauge: heavy dashes for the used
 * share, then `12% / 1M ──` at the right end, inset like the top border.
 * Returns undefined when there is nothing to measure.
 */
export const drawGauge = (
  state: ChromeState,
  width: number,
  hidden: number,
  border: (text: string) => string,
): string | undefined => {
  const ctx = state.ctx;
  if (!ctx || !ctx.model || width <= 0) return undefined;
  const theme = ctx.ui.theme;
  const usage = ctx.getContextUsage();
  const window = usage?.contextWindow || ctx.model.contextWindow || 0;
  const percent = usage?.percent == null ? undefined : Math.max(0, Math.min(100, usage.percent));
  const tone = (text: string) =>
    percent !== undefined && percent >= ERROR_PCT
      ? theme.fg("error", text)
      : percent !== undefined && percent >= WARN_PCT
        ? theme.fg("warning", text)
        : border(text);

  const pctText = percent === undefined ? "?" : `${Math.floor(percent)}%`;
  const windowText = window > 0 ? ` / ${formatTokens(window)}` : "";
  // pi's own `↓ N more` scroll hint lives in this border; keep it, shortened.
  const hint = hidden > 0 ? `↓${hidden}` : "";
  const variants: Array<{ hint: boolean; pct: boolean; window: boolean }> = [
    { hint: true, pct: true, window: true },
    { hint: true, pct: true, window: false },
    { hint: false, pct: true, window: false },
    { hint: false, pct: false, window: false },
  ];

  for (const variant of variants) {
    const plain: string[] = [];
    const styled: string[] = [];
    if (variant.hint && hint) {
      plain.push(hint);
      styled.push(theme.fg("dim", hint));
    }
    if (variant.pct) {
      const extra = variant.window ? windowText : "";
      plain.push(pctText + extra);
      styled.push(tone(pctText) + (extra ? theme.fg("dim", extra) : ""));
    }
    const rightPlain = plain.length > 0 ? ` ${plain.join(" ── ")} ──` : "";
    const bar = width - visibleWidth(rightPlain);
    if (plain.length > 0 && bar < MIN_BAR) continue;
    const used =
      percent === undefined ? 0 : Math.max(percent > 0 ? 1 : 0, Math.round((percent / 100) * bar));
    const right = plain.length > 0 ? ` ${styled.join(border(" ── "))}${border(" ──")}` : "";
    return (used > 0 ? tone(USED.repeat(used)) : "") + border(FREE.repeat(bar - used)) + right;
  }
  return undefined;
};
