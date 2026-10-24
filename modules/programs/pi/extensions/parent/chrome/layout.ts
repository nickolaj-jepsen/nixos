import type { Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import { visibleWidth, type TuiMouseEvent } from "@earendil-works/pi-tui";
import type { Action } from "./state.ts";

export type Part = {
  id: string;
  /** Plain text; its width is the part's width. */
  text: string;
  color: ThemeColor;
  /** Painted form; must have the same visible width as `text`. */
  styled?: (theme: Theme) => string;
  action?: Action;
  /** Painted bold when there is no `styled` form, so truncation keeps working. */
  bold?: boolean;
  /** What `text` collapses to when the line is squeezed; the layout swaps it in. */
  short?: string;
  /** Join to the previous part with one space instead of `GAP`. */
  tight?: boolean;
};

export type Region = { x0: number; x1: number; id: string; action: Action };

const GAP = 2;

const joinWidth = (part: Part, index: number) => (index === 0 ? 0 : part.tight ? 1 : GAP);

export const partsWidth = (parts: readonly Part[]) =>
  parts.reduce((sum, part, index) => sum + joinWidth(part, index) + visibleWidth(part.text), 0);

/**
 * Paints parts from column `x`, recording a click region for each part that has
 * an action. The clickable part whose id is `hovered` is lit.
 */
export const paintParts = (parts: readonly Part[], theme: Theme, x: number, hovered?: string) => {
  let column = x;
  let text = "";
  const regions: Region[] = [];
  parts.forEach((part, index) => {
    const join = joinWidth(part, index);
    text += " ".repeat(join);
    column += join;
    const width = visibleWidth(part.text);
    const lit = part.action !== undefined && part.id === hovered;
    // Hover brightens a dim part to the text colour; a part with its own colours goes bold.
    const body = part.styled
      ? lit
        ? theme.bold(part.styled(theme))
        : part.styled(theme)
      : theme.fg(lit ? "text" : part.color, part.bold ? theme.bold(part.text) : part.text);
    text += body;
    if (part.action)
      regions.push({ x0: column, x1: column + width, id: part.id, action: part.action });
    column += width;
  });
  return { text, regions };
};

const regionAt = (regions: readonly Region[], x: number) =>
  regions.find((region) => x >= region.x0 && x < region.x1);

export const hitTest = (regions: readonly Region[], x: number) => regionAt(regions, x)?.action;

export const hoverAt = (regions: readonly Region[], x: number) => regionAt(regions, x)?.id;

/** Modified clicks and drags stay with pi, so the transcript remains selectable. */
export const isPlainClick = (event: TuiMouseEvent) =>
  event.type === "click" && event.button === "left" && !event.alt && !event.shift && !event.ctrl;
