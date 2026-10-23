import { formatTokens } from "./format.ts";
import type { ChromeState } from "./state.ts";

const WARN_PCT = 60;
const ERROR_PCT = 85;

/**
 * The measurements for the editor's top border, from fullest to barest: context
 * with its window, then cost and speed, giving way from the right. Empty when
 * there is no model to measure.
 */
export const measurementLevels = (state: ChromeState, meters: readonly string[]): string[][] => {
  const ctx = state.ctx;
  if (!ctx?.model) return [];
  const theme = ctx.ui.theme;
  const usage = ctx.getContextUsage();
  const window = usage?.contextWindow || ctx.model.contextWindow || 0;
  const percent = usage?.percent == null ? undefined : Math.max(0, Math.min(100, usage.percent));
  // Only a number worth acting on leaves the neutral color.
  const color =
    percent !== undefined && percent >= ERROR_PCT
      ? "error"
      : percent !== undefined && percent >= WARN_PCT
        ? "warning"
        : "dim";

  const pct = percent === undefined ? "?" : `${Math.floor(percent)}%`;
  const windowText = window > 0 ? ` / ${formatTokens(window)}` : "";
  const context = theme.fg(color, pct) + (windowText ? theme.fg("dim", windowText) : "");
  const bare = theme.fg(color, pct);
  const extra = meters.map((text) => theme.fg("dim", text));

  return [
    ...Array.from({ length: extra.length + 1 }, (_, i) => [
      context,
      ...extra.slice(0, extra.length - i),
    ]),
    [bare],
  ];
};
