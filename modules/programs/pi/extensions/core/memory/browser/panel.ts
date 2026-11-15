/**
 * The rounded frame a full-panel overlay draws: a title on the top border with
 * an optional painted note at its right end, the body, and painted hints on the
 * bottom border. Callers own their layout and paint their own body and hints;
 * this only paints the four edges and the background, so panels cannot drift.
 */
import type { Theme, ThemeBg } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

export type FrameOptions = {
  /** Painted as given between `╭─` and the fill, spaces included. */
  title: string;
  /** Painted dim at the right end of the top border. */
  note?: string;
  /** Painted hints, spaces included; the caller colours them. */
  hints: string;
  /** Body lines, at most `frameWidth` visible characters each. */
  lines: readonly string[];
  /** Lines before the box divider, when the panel holds two panes. */
  split?: number;
  /** Fill behind the panel; every reset inside a line restores it. */
  background?: ThemeBg;
};

/** Columns a body line may use: the width less both borders and their padding. */
export const frameWidth = (width: number) => Math.max(10, width - 6);

const clip = (line: string, width: number) => truncateToWidth(`  ${line}`, width - 2, "…", true);

/** The frame around `options.lines` at `width` columns. */
export const frame = (theme: Theme, width: number, options: FrameOptions): string[] => {
  const border = (text: string) => theme.fg("borderMuted", text);
  const wide = (text: string) => visibleWidth(text);
  // A title, note or hint wider than the terminal is cut, not wrapped: the frame is one row.
  const fit = (text: string, max: number) =>
    wide(text) > max ? truncateToWidth(text, max, "…") : text;

  const noteText = options.note ? fit(` ${options.note} `, Math.max(0, width - 12)) : "";
  const title = fit(options.title, Math.max(4, width - 5 - wide(noteText)));
  const top =
    border("╭─") +
    theme.fg("accent", theme.bold(title)) +
    border("─".repeat(Math.max(0, width - 3 - wide(title) - wide(noteText)))) +
    (noteText ? theme.fg("dim", noteText) : "") +
    border("╮");

  const hints = fit(options.hints, Math.max(0, width - 4));
  const bottom =
    border(`╰${"─".repeat(Math.max(0, width - 3 - wide(hints)))}`) + hints + border("─╯");

  const body = options.lines.flatMap((line, index) => [
    ...(index === options.split ? [border(`├${"─".repeat(Math.max(0, width - 2))}┤`)] : []),
    border("│") + clip(line, width) + border("│"),
  ]);
  if (options.split === options.lines.length)
    body.push(border(`├${"─".repeat(Math.max(0, width - 2))}┤`));
  const lines = [top, ...body, bottom];
  if (!options.background) return lines;

  // Every reset inside a line would drop the panel background; put it back after each.
  const bg = theme.getBgAnsi(options.background);
  const onPanel = (line: string) =>
    bg + line.replace(/\x1b\[0?m/g, (reset) => reset + bg).replace(/\x1b\[49m/g, bg) + "\x1b[49m";
  return lines.map(onPanel);
};
