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
  /** Parts sharing a group light up together on hover; defaults to the part's own id. */
  group?: string;
  /** Painted bold when there is no `styled` form (so truncation keeps working). */
  bold?: boolean;
  /** Join to the previous part with one space instead of `GAP`. */
  tight?: boolean;
};

export type Region = { x0: number; x1: number; group: string; action: Action };

export const GAP = 2;

const joinWidth = (part: Part, index: number) => (index === 0 ? 0 : part.tight ? 1 : GAP);

export const partsWidth = (parts: readonly Part[]) =>
  parts.reduce((sum, part, index) => sum + joinWidth(part, index) + visibleWidth(part.text), 0);

/**
 * Paints parts from column `x`, recording a click region for each part that has
 * an action. Clickable parts of the `hovered` group are underlined.
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
    const group = part.group ?? part.id;
    let body = part.styled
      ? part.styled(theme)
      : theme.fg(part.color, part.bold ? theme.bold(part.text) : part.text);
    if (part.action && group === hovered) body = theme.underline(body);
    text += body;
    if (part.action) regions.push({ x0: column, x1: column + width, group, action: part.action });
    column += width;
  });
  return { text, regions };
};

const regionAt = (regions: readonly Region[], x: number) =>
  regions.find((region) => x >= region.x0 && x < region.x1);

export const hitTest = (regions: readonly Region[], x: number) => regionAt(regions, x)?.action;

export const hoverAt = (regions: readonly Region[], x: number) => regionAt(regions, x)?.group;

/** Modified clicks and drags stay with pi, so the transcript remains selectable. */
export const isPlainClick = (event: TuiMouseEvent) =>
  event.type === "click" && event.button === "left" && !event.alt && !event.shift && !event.ctrl;
