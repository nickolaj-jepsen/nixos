/**
 * The inbox overlay (D3): every comment the review holds on one screen, moved
 * through with `j`/`k`, copied with `y`, and either closed or handed back to the
 * caller with enter, which attaches the review.
 *
 * A comment is a header naming where it is and its body wrapped under it, so a
 * long comment costs rows rather than columns and a narrow terminal still reads.
 * The frame is a share of the terminal rather than a constant: the rows that do
 * not fit are scrolled past, never clipped mid-row.
 *
 * Nothing is cached across frames — the terminal's width and height both change
 * under it — so `invalidate()` only has to ask for the repaint a theme change
 * needs.
 */
import type { Theme } from "@earendil-works/pi-coding-agent";
import {
  type Component,
  Key,
  matchesKey,
  truncateToWidth,
  visibleWidth,
  wrapTextWithAnsi,
} from "@earendil-works/pi-tui";
import type { InboxItem } from "./types.ts";

/** What the overlay settles its `ctx.ui.custom` promise with. */
export type InboxResult = "close" | "attach";

/** The part of pi's TUI the overlay reads, so a test can stand in for the terminal. */
export type InboxViewport = { rows: number; requestRender(): void };

/** Rows the transcript above and the editor below keep; the frame takes a share of the terminal. */
const RESERVED_ROWS = 8;
/** Narrower than this and a comment's body is not worth wrapping. */
const MIN_WIDTH = 24;
/** Columns the body is indented by, so it reads as belonging to its header. */
const BODY_INDENT = 4;
/** Two spaces between the location, the comment type and its author. */
const GAP = 2;

/** The location as C5 prints it, without the backticks: what `y` puts on the clipboard. */
export const locate = (item: InboxItem): string | undefined => {
  if (item.path === null) return undefined;
  const { startLine, endLine } = item;
  if (startLine === null) return item.path;
  if (endLine === null || endLine === startLine) return `${item.path}:${startLine}`;
  return `${item.path}:${startLine}-${endLine}`;
};

/** One line, no escape sequences: what a header field may be drawn as (B1). */
const header = (text: string) =>
  plain(text)
    .replace(/\s*\n\s*/g, " ")
    .trim();

/** The location as the terminal may show it; the clipboard gets `locate`'s raw path. */
export const shownLocation = (item: InboxItem): string | undefined => {
  const where = locate(item);
  return where === undefined ? undefined : header(where);
};

/**
 * Comment text is another process's data (B1) and it is drawn into the
 * terminal, so every escape sequence and control byte goes: a colour code or a
 * cursor move in a comment would otherwise reach the TUI's own output. Newlines
 * stay, because the wrapper uses them as paragraph breaks.
 */
const TERMINAL_SEQUENCE = /\x1b\[[0-?]*[ -/]*[@-~]|\x1b[\]P^_][\s\S]*?(?:\x07|\x1b\\)/g;
const plain = (text: string) =>
  text
    .replace(/\r\n?/g, "\n")
    .replace(TERMINAL_SEQUENCE, "")
    .replace(/[\x00-\x09\x0b-\x1f\x7f]/g, "");

/** One comment's rows: its header, then its body wrapped to the frame. */
type Block = { rows: string[]; height: number };

export class InboxOverlay implements Component {
  /** The highlighted comment; the only state the overlay keeps. */
  private index = 0;
  /** The first comment drawn last frame, so scrolling a long list stays put. */
  private offset = 0;
  private closed = false;
  private readonly viewport: InboxViewport;
  private readonly theme: Theme;
  private readonly items: readonly InboxItem[];
  private readonly sent: ReadonlySet<string>;
  private readonly done: (result: InboxResult) => void;
  private readonly copy: (item: InboxItem) => void;

  /**
   * @param viewport the terminal, for its height and its repaint
   * @param items every comment the review holds, oldest first
   * @param sent the ids already handed to the model, drawn dim
   * @param done settles the host's promise: `attach` leaves for the review
   * @param copy what `y` does with a location; the clipboard is not the overlay's
   */
  constructor(
    viewport: InboxViewport,
    theme: Theme,
    items: readonly InboxItem[],
    sent: ReadonlySet<string>,
    done: (result: InboxResult) => void,
    copy: (item: InboxItem) => void,
  ) {
    this.viewport = viewport;
    this.theme = theme;
    this.items = items;
    this.sent = sent;
    this.done = done;
    this.copy = copy;
  }

  /** Nothing is cached between frames, so a theme change is a repaint and nothing more. */
  invalidate(): void {
    this.viewport.requestRender();
  }

  handleInput(data: string): void {
    if (matchesKey(data, Key.up) || data === "k") {
      this.move(-1);
      return;
    }
    if (matchesKey(data, Key.down) || data === "j") {
      this.move(1);
      return;
    }
    if (data === "y") {
      const item = this.items[this.index];
      if (item !== undefined) this.copy(item);
      return;
    }
    if (matchesKey(data, Key.enter)) {
      this.finish("attach");
      return;
    }
    if (matchesKey(data, Key.escape) || data === "q") this.finish("close");
  }

  render(width: number): string[] {
    const w = Math.max(MIN_WIDTH, width);
    const inner = w - 2;
    const blocks = this.items.map((item, index) =>
      this.block(item, index, inner, this.sent.has(item.id)),
    );
    const budget = Math.max(1, this.viewport.rows - RESERVED_ROWS);
    const rows = this.frame(blocks, budget);

    const border = (text: string) => this.theme.fg("borderMuted", text);
    const cell = (text: string) =>
      border("│") + truncateToWidth(text, inner, "…", true) + border("│");
    const title = this.title();
    const hint = this.hint();
    // Both hug the frame's own width: a terminal narrower than the words still gets every row.
    const topFill = Math.max(0, inner - 1 - visibleWidth(title));
    const bottomFill = Math.max(0, inner - 1 - visibleWidth(hint));
    return [
      border("╭─") +
        truncateToWidth(title, Math.max(0, inner - 1), "…") +
        border("─".repeat(topFill)) +
        border("╮"),
      ...rows.map((text) => cell(text)),
      border(`╰${"─".repeat(bottomFill)}`) +
        this.theme.fg("dim", truncateToWidth(hint, Math.max(0, inner - 1), "…")) +
        border("─╯"),
    ];
  }

  private move(delta: number): void {
    const next = Math.max(0, Math.min(this.items.length - 1, this.index + delta));
    if (next === this.index) return;
    this.index = next;
    this.viewport.requestRender();
  }

  private finish(result: InboxResult): void {
    // Enter and escape can both arrive; the promise settles once.
    if (this.closed) return;
    this.closed = true;
    this.done(result);
  }

  /** The rows for the comments on screen, scrolled so the highlighted one is among them. */
  private frame(blocks: readonly Block[], budget: number): string[] {
    const heights = blocks.map((block) => block.height);
    const fit = (start: number) => {
      let used = 0;
      let end = start;
      while (end < blocks.length && used + (heights[end] ?? 0) <= budget) {
        used += heights[end] ?? 0;
        end += 1;
      }
      return { used, end };
    };

    let start = Math.max(0, Math.min(this.offset, blocks.length - 1));
    if (this.index < start) start = this.index;
    let window = fit(start);
    while (this.index >= window.end && start < this.index) {
      start += 1;
      window = fit(start);
    }
    this.offset = start;
    // A comment taller than the whole frame still has to be drawn, clipped at the
    // last row it can use rather than by a row of the border.
    const end = window.end === start ? start + 1 : window.end;
    const rows: string[] = [];
    for (let index = start; index < end; index += 1) {
      const block = blocks[index];
      if (block === undefined) continue;
      for (const row of block.rows) {
        if (rows.length >= budget) return rows;
        rows.push(row);
      }
    }
    return rows;
  }

  private title(): string {
    const pending = this.items.filter((item) => !this.sent.has(item.id)).length;
    const count = pending > 0 ? `· ${pending} new ` : "";
    return (
      this.theme.fg("accent", this.theme.bold(" Review inbox ")) + this.theme.fg("muted", count)
    );
  }

  private hint(): string {
    const where = ` ${this.index + 1}/${this.items.length} `;
    return ` j/k move · y copy · enter review · esc close${where}`;
  }

  private block(item: InboxItem, index: number, inner: number, sent: boolean): Block {
    const theme = this.theme;
    const mark = theme.fg("accent", index === this.index ? "> " : "  ");
    // The header carries three more fields from that same file, so they are
    // sanitised here like the body: a path or an author can hold escape bytes too.
    const location = shownLocation(item) ?? "(no file)";
    const type = item.type === null ? "" : `[${header(item.type)}]`;
    const author = item.author === null ? "" : header(item.author);
    const head = [location, type, author].filter((part) => part !== "").join(" ".repeat(GAP));
    // A delivered comment stays readable but recedes: what is still new is the point.
    const color = sent ? "dim" : "text";
    const body = plain(item.body);
    const wrapped =
      body.trim() === ""
        ? []
        : wrapTextWithAnsi(body, Math.max(1, inner - BODY_INDENT)).map(
            (line) => theme.fg("dim", " ".repeat(BODY_INDENT)) + theme.fg(color, line),
          );
    const rows = [mark + theme.fg(color, head), ...wrapped, ""];
    return { rows, height: rows.length };
  }
}
