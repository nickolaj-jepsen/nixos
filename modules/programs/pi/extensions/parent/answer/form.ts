/**
 * The answer form, drawn in the editor's place: one item per screen and a
 * review, every row and key chip clickable. A pick records the answer and
 * opens a note field; Enter there, empty or not, goes on to the next item. The
 * draft and every step through it are the Claude Code mod's core (lib/answer),
 * so both harnesses answer alike; this file only draws it and maps keys and
 * clicks onto those steps.
 */
import { getMarkdownTheme, type Theme } from "@earendil-works/pi-coding-agent";
import {
  type Component,
  type Focusable,
  Input,
  Key,
  Markdown,
  matchesKey,
  type TUI,
  type TuiMouseEvent,
  type TuiMouseEventResult,
  truncateToWidth,
  visibleWidth,
  wrapTextWithAnsi,
} from "@earendil-works/pi-tui";
import {
  type Answer,
  type Draft,
  type Entry,
  entries,
  type Form,
  go,
  isChosen,
  isReview,
  type Item,
  record,
  reply,
  said,
  setNote,
  skip,
  startEntry,
} from "../lib/answer/hooks/core.ts";

export type FormResult = { draft: Draft; fill: boolean };

type Act =
  | { kind: "entry"; index: number }
  | { kind: "note" | "back" | "forward" | "skip" | "review" | "fill" }
  | { kind: "goto"; index: number };

/** A drawn row: a whole-row target, or chips hit by column. */
type Row = { text: string; act?: Act; cells?: { start: number; end: number; act: Act }[] };

const MIN_WIDTH = 30;
/** Rows kept for the transcript and footer around the frame. */
const RESERVED_ROWS = 8;

export class AnswerForm implements Component, Focusable {
  private draft: Draft;
  /** The highlighted entry on an item's screen. */
  private cursor = 0;
  private editing: "text" | "note" | undefined;
  private readonly input = new Input({ prompt: "› ", placeholder: "" });
  /** First body row shown when the item is taller than the frame. */
  private offset = 0;
  private maxOffset = 0;
  /** Frame row → what a click there does, from the last render. */
  private hits = new Map<number, Row>();
  private renderedRows = 0;
  private isFocused = false;

  constructor(
    private readonly tui: TUI,
    private readonly theme: Theme,
    private readonly form: Form,
    draft: Draft,
    private readonly done: (result: FormResult) => void,
  ) {
    this.draft = draft;
    this.resetCursor();
  }

  get focused(): boolean {
    return this.isFocused;
  }

  set focused(value: boolean) {
    this.isFocused = value;
    this.input.focused = value && this.editing !== undefined;
  }

  invalidate(): void {}

  private get item(): Item | undefined {
    return this.form.items[this.draft.step];
  }

  private resetCursor(): void {
    const item = this.item;
    this.cursor = item ? startEntry(item, this.draft.answers[this.draft.step]) : 0;
  }

  /** Moves to the draft's step, fields closed and the cursor on its answer or recommendation. */
  private update(draft: Draft): void {
    if (draft.step !== this.draft.step) this.offset = 0;
    this.draft = draft;
    this.resetCursor();
    this.stopEditing();
  }

  private startEditing(field: "text" | "note"): void {
    const chosen = this.draft.answers[this.draft.step];
    const value =
      field === "note"
        ? isReview(this.form, this.draft)
          ? this.draft.note
          : (this.draft.notes[this.draft.step] ?? "")
        : chosen?.kind === "text"
          ? chosen.text
          : "";
    this.editing = field;
    this.input.setValue(value);
    this.input.focused = this.isFocused;
    this.tui.requestRender();
  }

  private stopEditing(): void {
    this.editing = undefined;
    this.input.focused = false;
    this.tui.requestRender();
  }

  /** Enter in a field: the write-in or the note is kept, and the form goes on. */
  private commit(): void {
    const { form } = this;
    const value = this.input.getValue();
    if (isReview(form, this.draft)) return this.update(setNote(form, this.draft, value));
    const kept =
      this.editing === "note"
        ? setNote(form, this.draft, value)
        : record(form, this.draft, { kind: "text", text: value });
    this.update(go(form, kept, kept.step + 1));
  }

  /** A pick: the answer is kept and its note field opens; a write-in opens its own. */
  private pick(entry: Entry): void {
    if (entry.kind === "write") return this.startEditing("text");
    const value: Answer = entry.kind === "accept" ? { kind: "accept" } : entry;
    this.draft = record(this.form, this.draft, value);
    this.startEditing("note");
  }

  private act(act: Act): void {
    const { form, draft } = this;
    switch (act.kind) {
      case "entry": {
        const entry = this.item && entries(this.item)[act.index];
        if (entry) {
          this.cursor = act.index;
          this.pick(entry);
        }
        return;
      }
      case "note":
        return this.startEditing("note");
      case "back":
        return this.update(go(form, draft, draft.step - 1));
      case "forward":
        return this.update(go(form, draft, draft.step + 1));
      case "skip":
        return this.update(skip(form, draft));
      case "review":
        return this.update(go(form, draft, form.items.length));
      case "goto":
        return this.update(go(form, draft, act.index));
      case "fill":
        if (!reply(form, draft)) return;
        return this.done({ draft, fill: true });
    }
  }

  private scroll(step: number): void {
    this.offset = Math.max(0, Math.min(this.maxOffset, this.offset + step));
    this.tui.requestRender();
  }

  handleInput(data: string): void {
    if (this.editing) {
      if (matchesKey(data, Key.escape)) this.stopEditing();
      else if (matchesKey(data, Key.enter)) this.commit();
      else {
        this.input.handleInput(data);
        this.tui.requestRender();
      }
      return;
    }
    if (matchesKey(data, Key.escape) || matchesKey(data, "ctrl+c")) {
      this.done({ draft: this.draft, fill: false });
      return;
    }
    if (matchesKey(data, Key.shift("up")) || matchesKey(data, Key.shift("down"))) {
      this.scroll(matchesKey(data, Key.shift("down")) ? 3 : -3);
      return;
    }
    const review = isReview(this.form, this.draft);
    const count = review ? this.form.items.length : this.item ? entries(this.item).length : 0;
    if (matchesKey(data, Key.up) || matchesKey(data, Key.down)) {
      this.cursor = (this.cursor + (matchesKey(data, Key.down) ? 1 : -1) + count) % count;
      this.tui.requestRender();
      return;
    }
    const digit = /^[1-9]$/.test(data) ? Number(data) - 1 : -1;
    if (digit >= 0 && digit < count) {
      this.act(review ? { kind: "goto", index: digit } : { kind: "entry", index: digit });
      return;
    }
    if (matchesKey(data, Key.enter)) {
      this.act(review ? { kind: "fill" } : { kind: "entry", index: this.cursor });
      return;
    }
    const keys: Record<string, Act["kind"]> = review
      ? { n: "note", b: "back" }
      : { b: "back", f: "forward", s: "skip", r: "review" };
    const kind =
      keys[data] ??
      (matchesKey(data, Key.left) || matchesKey(data, Key.shift("tab"))
        ? "back"
        : matchesKey(data, Key.right) || matchesKey(data, Key.tab)
          ? "forward"
          : undefined);
    if (kind && kind !== "entry" && kind !== "goto") this.act({ kind });
  }

  handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    // Zero-based from the top border, so a body row is the frame row itself.
    const inside = event.y >= 0 && event.y < this.renderedRows;
    if (event.type === "wheel" && event.wheelDelta) {
      if (!inside) return undefined;
      this.scroll(event.wheelDelta < 0 ? -1 : 1);
      return { handled: true };
    }
    const row = this.hits.get(event.y);
    const x = event.x - 1;
    const act =
      row?.cells?.find((c) => x >= c.start && x < c.end)?.act ??
      (row?.act && x < visibleWidth(row.text.trimEnd()) ? row.act : undefined);
    if (!act) return inside ? { handled: true } : undefined;
    if (event.type === "move" && act.kind === "entry" && act.index !== this.cursor) {
      this.cursor = act.index;
      this.tui.requestRender();
      return { handled: true };
    }
    if (event.type === "press") return { handled: true, focus: true };
    if (event.type !== "click" || event.button !== "left") return { handled: true };
    this.act(act);
    return { handled: true };
  }

  /** `k label` chips on one row, each its own click target. */
  private chips(list: [string, string, Act][]): Row {
    let text = "";
    const cells: Row["cells"] = [];
    for (const [key, label, act] of list) {
      if (text) text += "  ";
      const start = visibleWidth(text);
      text += `${this.theme.fg("accent", key)} ${label}`;
      cells.push({ start, end: visibleWidth(text), act });
    }
    return { text, cells };
  }

  private wrapped(text: string, width: number, style?: (s: string) => string, indent = ""): Row[] {
    return wrapTextWithAnsi(text, Math.max(8, width - indent.length)).map((line) => ({
      text: indent + (style ? style(line) : line),
    }));
  }

  private field(label: string, width: number): Row {
    return {
      text: `${this.theme.fg("dim", label)} ${this.input.render(width - label.length - 1)[0] ?? ""}`,
    };
  }

  private entryText(item: Item, entry: Entry): string {
    if (entry.kind === "write")
      return this.form.kind === "round" ? "Write your own answer" : "Something else";
    if (entry.kind === "accept") return `Yes: ${item.recommended || "as recommended"}`;
    const o = item.options[entry.index];
    return this.form.kind === "round" ? `${o?.key}. ${o?.text}` : (o?.text ?? "");
  }

  private shownAnswer(item: Item, a: Answer | null | undefined): string {
    if (!a) return this.theme.fg("dim", "skipped");
    if (a.kind === "text") return `"${a.text}"`;
    const index = a.kind === "option" ? a.index : item.recommendedOption;
    const words = index === undefined ? "" : `: ${item.options[index]?.text ?? ""}`;
    return `${said(item, a)}${words}`;
  }

  private itemRows(item: Item, width: number): Row[] {
    const t = this.theme;
    const chosen = this.draft.answers[this.draft.step];
    const note = this.draft.notes[this.draft.step] ?? "";
    const rows: Row[] = [...this.wrapped(item.title, width, (s) => t.bold(s)), { text: "" }];
    if (item.body) {
      const md = new Markdown(item.body, 0, 0, getMarkdownTheme()).render(Math.max(8, width));
      rows.push(...md.map((text) => ({ text })), { text: "" });
    }
    entries(item).forEach((entry, k) => {
      const isOn = isChosen(item, chosen, entry);
      const isCursor = k === this.cursor && !this.editing;
      const mark = isOn ? t.fg("success", " ✓") : "";
      const isRec = entry.kind === "option" && entry.index === item.recommendedOption;
      const rec = isRec ? t.fg("dim", " (recommended)") : "";
      const lines = wrapTextWithAnsi(this.entryText(item, entry), Math.max(8, width - 4));
      lines.forEach((line, i) => {
        const pointer = isCursor ? t.fg("accent", "›") : " ";
        const head = i === 0 ? `${pointer}${t.fg("accent", String(k + 1))} ` : "   ";
        const tail = i === lines.length - 1 ? rec + mark : "";
        const body = isCursor ? t.fg("accent", line) : isOn ? t.fg("success", line) : line;
        rows.push({ text: `${head}${body}${tail}`, act: { kind: "entry", index: k } });
      });
      const detail = entry.kind === "option" ? item.options[entry.index]?.detail : "";
      if (detail) rows.push(...this.wrapped(detail, width, (s) => t.fg("dim", s), "   "));
    });
    rows.push({ text: "" });
    if (chosen?.kind === "text" && this.editing !== "text")
      rows.push(...this.wrapped(`${t.fg("dim", "Your answer:")} ${chosen.text}`, width));
    if (this.editing === "text") rows.push(this.field("answer", width));
    if (this.editing === "note") rows.push(this.field("note", width));
    else if (note) rows.push(...this.wrapped(`${t.fg("dim", "Note:")} ${note}`, width));
    return rows;
  }

  private reviewRows(width: number): Row[] {
    const t = this.theme;
    const rows: Row[] = [];
    this.form.items.forEach((item, i) => {
      const note = this.draft.notes[i] ? t.fg("dim", ` — ${this.draft.notes[i]}`) : "";
      const key = i < 9 ? t.fg("accent", String(i + 1)) : " ";
      const text = `${key}  ${item.label}  ${this.shownAnswer(item, this.draft.answers[i])}${note}`;
      rows.push({ text: truncateToWidth(text, width, "…"), act: { kind: "goto", index: i } });
    });
    rows.push({ text: "" });
    if (this.editing === "note") rows.push(this.field("note", width));
    else if (this.draft.note)
      rows.push(...this.wrapped(`${t.fg("dim", "Note:")} ${this.draft.note}`, width));
    rows.push({ text: t.fg("dim", "The reply:") });
    const text = reply(this.form, this.draft);
    for (const line of (text || t.fg("dim", "(nothing answered yet)")).split("\n"))
      rows.push(...this.wrapped(line, width, undefined, "  "));
    return rows;
  }

  render(width: number): string[] {
    const t = this.theme;
    const w = Math.max(MIN_WIDTH, width);
    const inner = w - 2;
    const textWidth = inner - 2;
    const review = isReview(this.form, this.draft);
    const item = this.item;
    const body = review || !item ? this.reviewRows(textWidth) : this.itemRows(item, textWidth);
    while (body.length && !body[body.length - 1]?.text) body.pop();
    const actions = review
      ? this.chips([
          ["enter", "fill the prompt", { kind: "fill" }],
          ["n", "note", { kind: "note" }],
          ["b", "back", { kind: "back" }],
        ])
      : this.chips([
          ["b", "back", { kind: "back" }],
          ["f", "forward", { kind: "forward" }],
          ["s", "skip", { kind: "skip" }],
          ["r", "review", { kind: "review" }],
        ]);

    // The actions stay put; a tall item scrolls above them.
    const room = Math.max(4, this.tui.terminal.rows - RESERVED_ROWS - 4);
    this.maxOffset = Math.max(0, body.length - room);
    this.offset = Math.min(this.offset, this.maxOffset);
    const shown = body.slice(this.offset, this.offset + room);
    const rows = [...shown, { text: "" }, actions];

    const border = (s: string) => t.fg("borderMuted", s);
    const title = review
      ? ` ${t.fg("accent", "Review")} `
      : ` ${t.fg("accent", item?.label ?? "")} ${t.fg("dim", `${this.draft.step + 1} of ${this.form.items.length}`)} `;
    const keys = this.editing
      ? "enter goes on · esc leaves the field"
      : review
        ? "1-9 revisits · esc closes, answers kept"
        : "1-9 or enter answers · esc closes, answers kept";
    const hint = ` ${this.maxOffset ? "shift+↑↓ scrolls · " : ""}${keys} `;
    const topFill = Math.max(0, inner - 1 - visibleWidth(title));
    const bottomFill = Math.max(0, inner - 1 - visibleWidth(hint));
    const cell = (s: string) =>
      border("│") + " " + truncateToWidth(s, textWidth, "…", true) + " " + border("│");
    const lines = [
      border("╭─") + title + border("─".repeat(topFill)) + border("╮"),
      ...rows.map((row) => cell(row.text)),
      border(`╰${"─".repeat(bottomFill)}`) + t.fg("dim", hint) + border("─╯"),
    ];
    // Targets are measured from the text's own start, one padding column in.
    this.hits = new Map();
    rows.forEach((row, i) => {
      if (row.act || row.cells)
        this.hits.set(i + 1, {
          ...row,
          cells: row.cells?.map((c) => ({ ...c, start: c.start + 1, end: c.end + 1 })),
          text: ` ${row.text}`,
        });
    });
    this.renderedRows = lines.length;
    return lines;
  }
}
