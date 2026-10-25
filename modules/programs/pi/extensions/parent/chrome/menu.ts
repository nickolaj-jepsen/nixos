/**
 * A small popover above the footer for the footer's own controls. It holds the
 * keyboard while it is open: arrows and enter pick, escape closes. The pointer
 * selects on hover and runs on click, so nothing here needs a right button.
 * Clicking the footer control again, or clicking into the prompt, closes it:
 * those are the two outside clicks pi can route to a component.
 *
 * A row that cannot run keeps its place and says why; choosing it explains in a
 * notification instead of acting. The caller builds the rows when the menu
 * opens, so a poll that lands meanwhile cannot move them under the pointer.
 */
import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import {
  type Component,
  Key,
  matchesKey,
  type TUI,
  type TuiMouseEvent,
  type TuiMouseEventResult,
  truncateToWidth,
  visibleWidth,
} from "@earendil-works/pi-tui";

export type MenuRow = {
  id: string;
  label: string;
  /** A short note beside the label: a host, a state, a destination. */
  description?: string;
  /** Why the row cannot run; the row stays and reports this when chosen. */
  unavailable?: string;
  run?(ctx: ExtensionContext): void | Promise<void>;
};

export type Menu = {
  title: string;
  /** Short context beside the title, e.g. the repository the rows act on. */
  context?: string;
  rows: MenuRow[];
  /** Row to open on; the first row that can run when it is missing. */
  preferred?: string;
};

/** The click that opened the menu: its terminal column and the footer's width. */
export type MenuAnchor = { column: number; columns: number };

const MAX_WIDTH = 56;
const MIN_WIDTH = 24;
// Columns the popover keeps clear of the terminal edges.
const MARGIN = 4;
// Rows kept free below it, so the editor and footer stay visible.
const RESERVED_ROWS = 8;
const HINTS = "↑↓ enter esc";
// A row's label column: past this the note it explains is worth more than the rest.
const MAX_LABEL = 26;
const MAX_NOTE = 22;

const rowNote = (row: MenuRow) => row.unavailable ?? row.description ?? "";

/** The label and note columns, shared by every row so the menu cannot jump. */
const columns = (menu: Menu) => ({
  label: Math.min(MAX_LABEL, Math.max(0, ...menu.rows.map((row) => visibleWidth(row.label)))),
  note: Math.min(MAX_NOTE, Math.max(0, ...menu.rows.map((row) => visibleWidth(rowNote(row))))),
});

const menuWidth = (menu: Menu, anchor: MenuAnchor | undefined) => {
  const room = Math.max(MIN_WIDTH, (anchor?.columns ?? 80) - MARGIN);
  const { label, note } = columns(menu);
  const head =
    visibleWidth(` ${menu.title} `) + visibleWidth(menu.context ? ` ${menu.context} ` : "");
  const content = Math.max(head + 3, 5 + label + (note > 0 ? 2 + note : 0));
  return Math.min(room, Math.max(MIN_WIDTH, Math.min(MAX_WIDTH, content)));
};

class MenuPopover implements Component {
  private index = 0;
  private closed = false;
  private focusedValue = false;
  private blurTimer: ReturnType<typeof setTimeout> | undefined;

  /**
   * A click outside an overlay never reaches it, but a click on a focusable
   * component behind it moves focus away, and that is the one dismissal signal
   * the overlay receives. Blur can also be half of a redundant re-focus, so the
   * close waits a tick and a refocus cancels it.
   */
  get focused() {
    return this.focusedValue;
  }

  set focused(value: boolean) {
    this.focusedValue = value;
    if (value) {
      clearTimeout(this.blurTimer);
      this.blurTimer = undefined;
      return;
    }
    this.blurTimer ??= setTimeout(() => {
      this.blurTimer = undefined;
      this.finish(undefined);
    }, 0);
  }

  constructor(
    private readonly tui: TUI,
    private readonly theme: Theme,
    private readonly menu: Menu,
    private readonly width: number,
    private readonly done: (row: MenuRow | undefined) => void,
  ) {
    const preferred = menu.rows.findIndex((row) => row.id === menu.preferred && !row.unavailable);
    const first = menu.rows.findIndex((row) => !row.unavailable);
    this.index = Math.max(0, preferred >= 0 ? preferred : first);
  }

  invalidate() {}

  /** Close from outside, e.g. the footer clicked again while the menu is up. */
  cancel() {
    this.finish(undefined);
  }

  private finish(row: MenuRow | undefined) {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.blurTimer);
    this.blurTimer = undefined;
    this.done(row);
  }

  private room() {
    return Math.max(3, this.tui.terminal.rows - RESERVED_ROWS);
  }

  /** First row of the window and one past its last. */
  private window(): { start: number; end: number } {
    const count = this.menu.rows.length;
    const room = Math.min(this.room(), Math.max(1, count));
    const start = Math.max(0, Math.min(this.index - Math.floor(room / 2), count - room));
    return { start, end: Math.min(start + room, count) };
  }

  /** The row at a pointer position inside the frame, if it is over one. */
  private rowAt(y: number): number | undefined {
    const { start, end } = this.window();
    // Row zero is the top border; the rows themselves start under it.
    const index = start + y - 1;
    return index >= start && index < end ? index : undefined;
  }

  private move(step: number) {
    const count = this.menu.rows.length;
    if (count === 0) return;
    this.index = (((this.index + step) % count) + count) % count;
    this.tui.requestRender();
  }

  handleInput(data: string) {
    if (matchesKey(data, Key.escape) || matchesKey(data, "ctrl+c")) {
      this.finish(undefined);
      return;
    }
    if (matchesKey(data, Key.enter)) {
      this.finish(this.menu.rows[this.index]);
      return;
    }
    const step =
      matchesKey(data, Key.up) || data === "k"
        ? -1
        : matchesKey(data, Key.down) || data === "j"
          ? 1
          : matchesKey(data, Key.pageUp)
            ? -5
            : matchesKey(data, Key.pageDown)
              ? 5
              : 0;
    if (step !== 0) this.move(step);
  }

  handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    if (event.type === "wheel" && event.wheelDelta) {
      this.move(event.wheelDelta < 0 ? -1 : 1);
      return { handled: true };
    }
    // Hover follows the pointer like a list would; a move carries no button.
    if (event.type === "move") {
      const index = this.rowAt(event.y);
      if (index !== undefined && index !== this.index) {
        this.index = index;
        this.tui.requestRender();
      }
      return { handled: true };
    }
    if (event.button !== "left" || (event.type !== "press" && event.type !== "click")) {
      return undefined;
    }
    const index = this.rowAt(event.y);
    if (index === undefined) return undefined;
    const changed = index !== this.index;
    this.index = index;
    if (event.type === "press") {
      if (changed) this.tui.requestRender();
      return { handled: true, focus: true };
    }
    this.finish(this.menu.rows[index]);
    return { handled: true };
  }

  render(width: number): string[] {
    const theme = this.theme;
    const w = Math.max(1, Math.min(width, this.width));
    // A terminal narrower than the chrome is not worth a frame.
    if (w < 12) return [truncateToWidth(` ${this.menu.title} `, w)];
    const inner = w - 2;
    const border = (text: string) => theme.fg("borderMuted", text);
    const cell = (content: string) =>
      border("│") + truncateToWidth(content, inner, "…", true) + border("│");

    const title = ` ${this.menu.title} `;
    const context = this.menu.context ? ` ${this.menu.context} ` : "";
    const topFill = Math.max(0, inner - 1 - visibleWidth(title) - visibleWidth(context));
    const hints = ` ${HINTS} `;
    const bottomFill = Math.max(0, inner - 1 - visibleWidth(hints));
    const { label: labelWidth, note: noteWidth } = columns(this.menu);
    const { start, end } = this.window();

    const rows = this.menu.rows.slice(start, end).map((row, offset) => {
      const selected = start + offset === this.index;
      const prefix = selected ? theme.fg("accent", "▸ ") : "  ";
      const label = truncateToWidth(row.label, labelWidth, "…");
      const labelText = selected
        ? theme.bold(theme.fg(row.unavailable ? "muted" : "accent", label))
        : theme.fg(row.unavailable ? "muted" : "text", label);
      const note = rowNote(row);
      const noteText = note
        ? `  ${theme.fg(
            row.unavailable ? "warning" : "muted",
            truncateToWidth(note, noteWidth, "…"),
          )}`
        : "";
      const pad = " ".repeat(Math.max(0, labelWidth - visibleWidth(label)));
      return cell(`${prefix}${labelText}${pad}${noteText}`);
    });

    return [
      border("╭─") +
        theme.fg("accent", theme.bold(title)) +
        theme.fg("muted", context) +
        border("─".repeat(topFill)) +
        border("╮"),
      ...rows,
      border(`╰${"─".repeat(bottomFill)}`) + theme.fg("dim", hints) + border("─╯"),
    ];
  }
}

export const createMenuPopper = () => {
  let current: MenuPopover | undefined;

  /** Closes the open menu, if any. */
  const close = () => {
    const open = current;
    current = undefined;
    open?.cancel();
  };

  /**
   * Shows `menu` above the footer, aligned to the click that asked for it. A
   * second open while one is up closes it rather than stacking: the footer is the
   * control that opened it, and the only click target pi will hand to it again
   * (the rest of the screen goes elsewhere, except the prompt's focus loss).
   */
  const open = async (ctx: ExtensionContext, menu: Menu, anchor?: MenuAnchor): Promise<void> => {
    if (ctx.mode !== "tui") {
      ctx.ui.notify("chrome: the menus need an interactive terminal", "warning");
      return;
    }
    if (current) {
      close();
      return;
    }
    const width = menuWidth(menu, anchor);
    const columns = anchor?.columns ?? 80;
    const col = Math.max(1, Math.min((anchor?.column ?? 3) - 4, columns - width - 1));
    const picked = await ctx.ui.custom<MenuRow | undefined>(
      (tui, theme, _keybindings, done) => {
        const popover = new MenuPopover(tui, theme, menu, width, (row) => {
          current = undefined;
          done(row);
        });
        current = popover;
        return popover;
      },
      { overlay: true, overlayOptions: { anchor: "bottom-left", offsetY: -1, width, col } },
    );
    if (!picked) return;
    if (picked.unavailable) {
      ctx.ui.notify(picked.unavailable, "warning");
      return;
    }
    try {
      await picked.run?.(ctx);
    } catch (error) {
      ctx.ui.notify(`chrome: ${String(error)}`, "error");
    }
  };

  return { open, close, isOpen: () => current !== undefined };
};
