import { visibleWidth } from "@earendil-works/pi-tui";
import { formatTokens } from "./format.ts";
import type { ChromeState } from "./state.ts";

const FILL = "─";
const WARN_PCT = 60;
const ERROR_PCT = 85;
// Fewer plain dashes than this and the border stops reading as a border, so text goes first.
const MIN_FILL = 4;

/**
 * The editor's bottom border with the measurements at its right end,
 * `── 12% / 1M ── $0.10 ── 26 t/s ──`, inset like the top border. `meters` are
 * extra measurements in the order they give way when the border is narrow.
 * Returns undefined when there is nothing to measure.
 */
export const drawMeters = (
  state: ChromeState,
  width: number,
  hidden: number,
  border: (text: string) => string,
  meters: readonly string[] = [],
): string | undefined => {
  const ctx = state.ctx;
  if (!ctx || !ctx.model || width <= 0) return undefined;
  const theme = ctx.ui.theme;
  const usage = ctx.getContextUsage();
  const window = usage?.contextWindow || ctx.model.contextWindow || 0;
  const percent = usage?.percent == null ? undefined : Math.max(0, Math.min(100, usage.percent));
  // Only a number worth acting on leaves the neutral color.
  const pctColor =
    percent !== undefined && percent >= ERROR_PCT
      ? "error"
      : percent !== undefined && percent >= WARN_PCT
        ? "warning"
        : "dim";

  const pctText = percent === undefined ? "?" : `${Math.floor(percent)}%`;
  const windowText = window > 0 ? ` / ${formatTokens(window)}` : "";
  // pi's own `↓ N more` scroll hint lives in this border; keep it, shortened.
  const hint = hidden > 0 ? `↓${hidden}` : "";
  const variants: Array<{ hint: boolean; pct: boolean; window: boolean; meters: number }> = [
    ...Array.from({ length: meters.length + 1 }, (_, i) => ({
      hint: true,
      pct: true,
      window: true,
      meters: meters.length - i,
    })),
    { hint: true, pct: true, window: false, meters: 0 },
    { hint: false, pct: true, window: false, meters: 0 },
    { hint: false, pct: false, window: false, meters: 0 },
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
      styled.push(theme.fg(pctColor, pctText) + (extra ? theme.fg("dim", extra) : ""));
    }
    for (const meter of meters.slice(0, variant.meters)) {
      plain.push(meter);
      styled.push(theme.fg("dim", meter));
    }
    const rightPlain = plain.length > 0 ? ` ${plain.join(" ── ")} ──` : "";
    const fill = width - visibleWidth(rightPlain);
    if (plain.length > 0 && fill < MIN_FILL) continue;
    const right = plain.length > 0 ? ` ${styled.join(border(" ── "))}${border(" ──")}` : "";
    return border(FILL.repeat(fill)) + right;
  }
  return undefined;
};
