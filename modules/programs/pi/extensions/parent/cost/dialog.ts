/**
 * The panel: a rounded frame over the transcript holding the one pane, which
 * scrolls only when the terminal is too short for it.
 */
import type { Theme } from "@earendil-works/pi-coding-agent";
import {
  Key,
  matchesKey,
  truncateToWidth,
  visibleWidth,
  type Component,
  type TUI,
} from "@earendil-works/pi-tui";
import { pane } from "./pane.ts";
import type { View } from "./view.ts";

// Rows kept free around the overlay, so the editor border stays in view.
const MARGIN_ROWS = 4;
const PANEL_BG = "userMessageBg";

export class CostDialog implements Component {
  private scroll = 0;
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

  /** The view may have changed (a usage refresh, a new entry); redraw it. */
  refresh() {
    this.tui.requestRender();
  }

  invalidate() {}

  handleInput(data: string) {
    if (matchesKey(data, Key.escape) || matchesKey(data, Key.enter) || data === "q") {
      this.done();
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
    // A border and two columns of padding either side: what the pane may draw in.
    const inner = Math.max(10, width - 6);
    const room = Math.max(3, this.tui.terminal.rows - MARGIN_ROWS - 2);
    const body = [...pane(this.view(), theme, inner), ""];
    this.scroll = Math.min(this.scroll, Math.max(0, body.length - room));
    const shown = body.slice(this.scroll, this.scroll + room);

    // Every reset inside a line would drop the panel background; put it back after each.
    const bg = theme.getBgAnsi(PANEL_BG);
    const onPanel = (line: string) =>
      bg + line.replace(/\x1b\[0?m/g, (reset) => reset + bg).replace(/\x1b\[49m/g, bg) + "\x1b[49m";
    const border = (text: string) => theme.fg("borderMuted", text);
    const pad = (line: string) => truncateToWidth(`  ${line}`, width - 2, "…", true);

    const title = " Session cost ";
    const hints = [body.length > room ? `↑↓ ${this.scroll + 1}/${body.length}` : "", "esc close"];
    const footer = ` ${hints.filter(Boolean).join(" · ")} `;
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
