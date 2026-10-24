import type { ContextUsage, Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import { formatTokens } from "./format.ts";
import type { Action, ChromeState } from "./state.ts";

/** One measurement on the border, painted; one with an action is a control lit on hover. */
export type Segment = {
  text: string;
  id?: string;
  action?: Action;
  /** Columns of extra click target on each side; neighbours split any overlap. */
  hitPad?: number;
};

/** A measurement as the footer computes it, before painting. */
export type Meter = { id: string; text: string; action?: Action };

/** What the footer measured for the border: pi's context usage and the meters beside it. */
export type Measurements = { context: ContextUsage | undefined; meters: readonly Meter[] };

/** The border's two controls over how much room the transcript spends. */
export type Toggles = { tools: Action; thinking: Action; thinkingOpen: boolean };

// The Nerd Font range: present in Hack Nerd Font, where a text glyph like U+2692
// would come from another font at another width and misalign the row. The
// terminal sits in a box rather than as a bare `>_`, whose underscore pulls its
// ink below the dashes beside it.
const GLYPH_TOOLS = "\uf489";
const GLYPH_THINKING = "\uf0eb";

// A one-cell glyph is a small target; the separator absorbs the rest.
const CHIP_HIT_PAD = 2;

const WARN_PCT = 60;
const ERROR_PCT = 85;

/** Only a context fill worth acting on leaves the neutral color. */
export const contextColor = (percent: number | undefined): ThemeColor =>
  percent !== undefined && percent >= ERROR_PCT
    ? "error"
    : percent !== undefined && percent >= WARN_PCT
      ? "warning"
      : "dim";

/** Lit while the content is open, dim while condensing, bright under the pointer. */
const toggleChip = (
  state: ChromeState,
  theme: Theme,
  id: string,
  glyph: string,
  open: boolean,
  action: Action,
): Segment => {
  const hovered = state.hover === id;
  return {
    id,
    action,
    hitPad: CHIP_HIT_PAD,
    text: hovered
      ? theme.fg("text", theme.bold(glyph))
      : open
        ? theme.fg("accent", theme.bold(glyph))
        : theme.fg("dim", glyph),
  };
};

/**
 * The two controls ahead of the measurements. Each reports the flag pi already
 * owns, so ctrl+o and alt+t stay authoritative and a click reads as one more key.
 */
const chipSegments = (state: ChromeState, toggles: Toggles): Segment[] => {
  const ctx = state.ctx;
  if (!ctx) return [];
  const theme = ctx.ui.theme;
  const toolsOpen = ctx.ui.getToolsExpanded();
  return [
    toggleChip(state, theme, "tools", GLYPH_TOOLS, toolsOpen, toggles.tools),
    toggleChip(state, theme, "thinking", GLYPH_THINKING, toggles.thinkingOpen, toggles.thinking),
  ];
};

/**
 * The measurements for the editor's top border, from fullest to barest: context
 * with its window, then cost and speed, giving way from the right. Empty when
 * there is no model to measure.
 *
 * The toggles lead every level, so a narrow terminal drops the numbers before it
 * drops the controls.
 */
export const measurementLevels = (
  state: ChromeState,
  { context: usage, meters }: Measurements,
  toggles?: Toggles,
): Segment[][] => {
  const ctx = state.ctx;
  if (!ctx?.model) return [];
  const theme = ctx.ui.theme;
  const chips = toggles ? chipSegments(state, toggles) : [];
  const window = usage?.contextWindow || ctx.model.contextWindow || 0;
  const percent = usage?.percent == null ? undefined : Math.max(0, Math.min(100, usage.percent));
  const color = contextColor(percent);

  const pct = percent === undefined ? "?" : `${Math.floor(percent)}%`;
  const windowText = window > 0 ? ` / ${formatTokens(window)}` : "";
  const context = { text: theme.fg(color, pct) + (windowText ? theme.fg("dim", windowText) : "") };
  const bare = { text: theme.fg(color, pct) };
  const extra = meters.map(({ id, text, action }) => ({
    id,
    action,
    text: theme.fg(action && state.hover === id ? "text" : "dim", text),
  }));

  return [
    ...Array.from({ length: extra.length + 1 }, (_, i) => [
      ...chips,
      context,
      ...extra.slice(0, extra.length - i),
    ]),
    [...chips, bare],
  ];
};
