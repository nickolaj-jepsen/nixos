/**
 * The questionnaire: one tab per question, a review tab when there is more
 * than one, and the pointer wired to the same actions as the keys.
 *
 * Sizing is layout rather than taste. A question with four described options
 * does not fit a twenty-row terminal alongside a preview pane, so the frame is
 * built three ways — descriptions, then without them, then without the preview
 * — and the first that fits the row budget is drawn. Options are few enough
 * that windowing them would cost more than it explains.
 *
 * Nothing is cached between frames: the answers, the highlighted row and the
 * preview all move together, and a cache would be one more thing to invalidate.
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
  type Question,
  type QuestionsResult,
  TYPE_SOMETHING,
  type QuestionAnswer,
} from "./types.ts";

/** Beyond this the frame stops widening: a question is not a table. */
const MAX_WIDTH = 96;
const MIN_WIDTH = 28;
/** Below this the preview sits under the options instead of beside them. */
const SIDE_BY_SIDE_WIDTH = 88;
/**
 * Rows kept for the transcript and footer above and below the frame. The
 * budget is a share of the terminal rather than a constant, so a tall terminal
 * shows more of the question instead of more empty space.
 */
const RESERVED_ROWS = 10;
const MAX_BUDGET = 24;
const PREVIEW_ROWS = 8;
const UNDER_PREVIEW_ROWS = 4;

/** What the frame gives up when the whole of it does not fit. */
interface Attempt {
  preview: boolean;
  window: boolean;
  /** Which rows explain themselves: all of them, only the highlighted one, or none. */
  descriptions: "all" | "highlighted" | "none";
  /** Lines a description is clipped to, with an ellipsis, when even one will not fit. */
  clip?: number;
  /** Lines the question itself is capped to, to leave the answers their room. */
  questionLines?: number;
}

/** Where the answer text and the preview sit in this frame. */
interface Layout {
  /** The frame's inside width. */
  inner: number;
  /** Width the answer text wraps to: the left column when a preview is beside it. */
  textWidth: number;
  /** The preview column, when it sits beside the options. */
  side?: number;
  /** The preview column, when it sits under the options. */
  under?: number;
  /** The markdown to preview, when the highlighted row has one. */
  markdown?: string;
}

type Item =
  | { kind: "option"; index: number }
  | { kind: "custom" }
  | { kind: "note" }
  | { kind: "done" }
  | { kind: "review"; question: number }
  | { kind: "send" }
  | { kind: "cancel" };

type Tab = { kind: "question"; index: number } | { kind: "review" };

/** What the user has said so far for one question; picks and text exclude each other. */
interface Draft {
  picked: number[];
  text: string;
}

/** A rendered row and the click target it carries, if any. */
interface BodyRow {
  text: string;
  hit?: Item;
}

const isAnswered = (draft: Draft) => draft.picked.length > 0 || draft.text.trim() !== "";

const pad = (text: string, width: number) =>
  text + " ".repeat(Math.max(0, width - visibleWidth(text)));

const column = (text: string, width: number) => pad(truncateToWidth(text, width, "…"), width);

export class QuestionsDialog implements Component, Focusable {
  private readonly tabs: Tab[];
  private readonly drafts: Draft[];
  /** The answer field and the note field, each with its own cursor, undo and paste. */
  private readonly input: Input;
  private readonly noteInput: Input;
  private tab = 0;
  private row = 0;
  private editing: "answer" | "note" | undefined;
  /** One note per question, included with its answer in the result. */
  private readonly notes: string[];
  /** First line of a question too tall for the frame, and how far it can go. */
  private questionOffset = 0;
  private questionMaxOffset = 0;
  /** The question's rows in the last frame, for wheeling over its text. */
  private questionRows: { start: number; end: number } = { start: 0, end: 0 };
  private warning: string | undefined;
  private closed = false;
  private isFocused = false;
  private hits = new Map<number, Item>();
  /** Rows the last frame drew, borders included. */
  private renderedRows = 0;
  private tabCells: { start: number; end: number; tab: number }[] = [];
  private tabRow = -1;

  constructor(
    private readonly tui: TUI,
    private readonly theme: Theme,
    private readonly questions: readonly Question[],
    private readonly done: (result: QuestionsResult) => void,
  ) {
    this.tabs = questions.map((_, index) => ({ kind: "question", index }) as const);
    // The review step earns its rows only when there is more than one answer to check.
    if (questions.length > 1) this.tabs.push({ kind: "review" });
    this.drafts = questions.map(() => ({ picked: [], text: "" }));
    this.notes = questions.map(() => "");
    this.input = new Input({ prompt: "✎ ", placeholder: "Your answer" });
    this.noteInput = new Input({ prompt: "✎ ", placeholder: "Your note" });
  }

  /** Inline rather than an overlay: the transcript stays readable behind it. */
  get focused(): boolean {
    return this.isFocused;
  }

  set focused(value: boolean) {
    this.isFocused = value;
    this.input.focused = value && this.editing === "answer";
    this.noteInput.focused = value && this.editing === "note";
  }

  invalidate(): void {}

  /** The field being edited; only meaningful while `editing` is set. */
  private get editingInput(): Input {
    return this.editing === "note" ? this.noteInput : this.input;
  }

  private get tabKind(): Tab {
    return this.tabs[this.tab] ?? this.tabs[0]!;
  }

  /** The question the current tab edits, if it edits one. */
  private get questionIndex(): number | undefined {
    const kind = this.tabKind;
    return kind.kind === "question" ? kind.index : undefined;
  }

  private get question(): Question | undefined {
    const index = this.questionIndex;
    return index === undefined ? undefined : this.questions[index];
  }

  private items(): Item[] {
    const question = this.question;
    if (!question) {
      return [
        ...this.questions.map((_, index) => ({ kind: "review", question: index }) as Item),
        { kind: "send" },
        { kind: "cancel" },
      ];
    }
    const items: Item[] = question.options.map((_, index) => ({ kind: "option", index }));
    items.push({ kind: "custom" });
    items.push({ kind: "note" });
    if (question.multiSelect) items.push({ kind: "done" });
    return items;
  }

  private move(step: number): void {
    if (this.editing) return;
    const count = this.items().length;
    if (count === 0) return;
    this.row = (((this.row + step) % count) + count) % count;
    this.warning = undefined;
    this.tui.requestRender();
  }

  private goTab(tab: number): void {
    this.keepDraft();
    this.questionOffset = 0;
    this.tab = Math.max(0, Math.min(tab, this.tabs.length - 1));
    this.row = 0;
    this.editing = undefined;
    this.input.focused = false;
    this.noteInput.focused = false;
    this.warning = undefined;
    this.tui.requestRender();
  }

  private cycleTab(step: number): void {
    if (this.tabs.length < 2) return;
    this.goTab((this.tab + step + this.tabs.length) % this.tabs.length);
  }

  /** Move a question too tall for the frame; idle when the whole text is on screen. */
  private scrollQuestion(step: number): void {
    if (this.questionMaxOffset === 0) return;
    const next = Math.max(0, Math.min(this.questionMaxOffset, this.questionOffset + step));
    if (next === this.questionOffset) return;
    this.questionOffset = next;
    this.tui.requestRender();
  }

  private startEditing(field: "answer" | "note"): void {
    const index = this.questionIndex;
    if (index === undefined) return;
    this.editing = field;
    this.warning = undefined;
    this.input.focused = this.isFocused && field === "answer";
    this.noteInput.focused = this.isFocused && field === "note";
    this.editingInput.setValue(field === "note" ? this.notes[index]! : this.drafts[index]!.text);
    this.tui.requestRender();
  }

  /** Leaving the field, or the tab, keeps what was typed as a draft on the row. */
  private keepDraft(): void {
    const index = this.questionIndex;
    if (this.editing === undefined || index === undefined) return;
    if (this.editing === "note") this.notes[index] = this.noteInput.getValue();
    else this.drafts[index]!.text = this.input.getValue();
  }

  private stopEditing(): void {
    this.keepDraft();
    this.editing = undefined;
    this.input.focused = false;
    this.noteInput.focused = false;
    this.warning = undefined;
    this.tui.requestRender();
  }

  /**
   * Save the field and, for an answer, move on.
   *
   * A note saves in place: it is commentary on a question, not the decision, so
   * entering one must not carry the user off the tab they were reading.
   */
  private commitText(): void {
    const index = this.questionIndex;
    if (index === undefined) return;
    const text = this.editingInput.getValue().trim();
    if (this.editing === "note") {
      this.notes[index] = text;
      this.editing = undefined;
      this.input.focused = false;
      this.noteInput.focused = false;
      this.warning = undefined;
      this.tui.requestRender();
      return;
    }
    if (!text) {
      this.warning = "Type an answer, or press esc to go back";
      this.tui.requestRender();
      return;
    }
    this.drafts[index] = { picked: [], text };
    this.editing = undefined;
    this.input.focused = false;
    this.advance();
  }

  /** Take an option: a single-select answer is complete, a multi-select one is a toggle. */
  private choose(index: number): void {
    const question = this.question;
    const at = this.questionIndex;
    if (!question || at === undefined) return;
    const draft = this.drafts[at]!;
    if (question.multiSelect) {
      const picked = draft.picked.includes(index)
        ? draft.picked.filter((candidate) => candidate !== index)
        : [...draft.picked, index].sort((left, right) => left - right);
      this.drafts[at] = { picked, text: "" };
      this.warning = undefined;
      this.tui.requestRender();
      return;
    }
    this.drafts[at] = { picked: [index], text: "" };
    this.advance();
  }

  /** Move on the way a click on an option would: to the next open question, else to review. */
  private advance(): void {
    this.warning = undefined;
    if (this.tabs.length === 1) {
      this.submit();
      return;
    }
    const open = this.drafts.findIndex((draft) => !isAnswered(draft));
    this.goTab(open >= 0 ? open : this.tabs.length - 1);
  }

  private submit(): void {
    const open = this.drafts.findIndex((draft) => !isAnswered(draft));
    if (open >= 0) {
      this.goTab(open);
      this.warning = `Answer question ${open + 1} first`;
      this.tui.requestRender();
      return;
    }
    const answers: QuestionAnswer[] = [];
    this.questions.forEach((question, index) => {
      const draft = this.drafts[index]!;
      const text = draft.text.trim();
      const values = text
        ? [text]
        : draft.picked.flatMap((picked) => {
            const option = question.options[picked];
            return option ? [option.label] : [];
          });
      if (values.length > 0) {
        const note = this.notes[index]?.trim() ?? "";
        answers.push({
          header: question.header,
          question: question.question,
          values,
          ...(note ? { note } : {}),
        });
      }
    });
    this.finish({ answers, cancelled: false });
  }

  private cancel(): void {
    this.finish({ answers: [], cancelled: true });
  }

  private finish(result: QuestionsResult): void {
    if (this.closed) return;
    this.closed = true;
    this.input.focused = false;
    this.done(result);
  }

  /** The action a row performs, whichever way it was reached. */
  private activate(item: Item): void {
    if (this.editing !== undefined && item.kind !== this.editing) this.stopEditing();
    switch (item.kind) {
      case "option":
        this.choose(item.index);
        return;
      case "custom":
        this.startEditing("answer");
        return;
      case "note":
        this.startEditing("note");
        return;
      case "done":
        if ((this.drafts[this.questionIndex ?? 0]?.picked.length ?? 0) === 0) {
          this.warning = "Select at least one option";
          this.tui.requestRender();
          return;
        }
        this.advance();
        return;
      case "review":
        this.goTab(item.question);
        return;
      case "send":
        this.submit();
        return;
      case "cancel":
        this.cancel();
        return;
    }
  }

  handleInput(data: string): void {
    if (this.editing) {
      this.handleEditingInput(data);
      return;
    }
    if (matchesKey(data, Key.escape) || matchesKey(data, "ctrl+c")) {
      this.cancel();
      return;
    }
    if (matchesKey(data, Key.up) || data === "k") {
      this.move(-1);
      return;
    }
    if (matchesKey(data, Key.down) || data === "j") {
      this.move(1);
      return;
    }
    if (matchesKey(data, Key.tab) || matchesKey(data, Key.right)) {
      this.cycleTab(1);
      return;
    }
    if (matchesKey(data, Key.shift("tab")) || matchesKey(data, Key.left)) {
      this.cycleTab(-1);
      return;
    }
    // Shift+arrows, not the page keys: fullscreen's own viewport listener
    // claims PageUp/PageDown before a focused inline component sees them.
    if (matchesKey(data, Key.shift("up")) || matchesKey(data, Key.shift("down"))) {
      this.scrollQuestion(matchesKey(data, Key.shift("down")) ? 3 : -3);
      return;
    }
    if (data === "n" && this.question) {
      this.row = this.items().findIndex((item) => item.kind === "note");
      this.startEditing("note");
      return;
    }
    if (matchesKey(data, Key.enter)) {
      const item = this.items()[this.row];
      if (item) this.activate(item);
      return;
    }
    if (data === " ") {
      const item = this.items()[this.row];
      const question = this.question;
      if (item?.kind === "option" && question?.multiSelect) this.choose(item.index);
      return;
    }
    // A digit picks the option it numbers, the way the row prints it.
    const digit = /^[1-9]$/.test(data) ? Number(data) - 1 : -1;
    const question = this.question;
    if (digit >= 0 && question && digit < question.options.length) {
      this.row = digit;
      this.choose(digit);
    }
  }

  private handleEditingInput(data: string): void {
    if (matchesKey(data, Key.escape)) {
      this.stopEditing();
      return;
    }
    if (matchesKey(data, Key.enter)) {
      this.commitText();
      return;
    }
    if (matchesKey(data, Key.tab) || matchesKey(data, Key.shift("tab"))) {
      this.cycleTab(matchesKey(data, Key.tab) ? 1 : -1);
      return;
    }
    this.editingInput.handleInput(data);
    this.tui.requestRender();
  }

  /** Line index of the row under the pointer, from this frame's hit map. */
  private itemAt(y: number): Item | undefined {
    return this.hits.get(y);
  }

  handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    if (event.type === "wheel" && event.wheelDelta) {
      const overText = event.y >= this.questionRows.start && event.y < this.questionRows.end;
      if (overText && this.questionMaxOffset > 0) {
        this.scrollQuestion(event.wheelDelta < 0 ? -1 : 1);
        return { handled: true };
      }
      this.move(event.wheelDelta < 0 ? -1 : 1);
      return { handled: true };
    }
    // A tab row is a strip of chips, so it hit-tests by column, not by row.
    if (event.y === this.tabRow) {
      const x = event.x - 1;
      const cell = this.tabCells.find((candidate) => x >= candidate.start && x < candidate.end);
      if (!cell) return undefined;
      if (event.type === "press") return { handled: true, focus: true };
      if (event.type === "click") {
        this.goTab(cell.tab);
        return { handled: true };
      }
      return undefined;
    }
    const item = this.itemAt(event.y);
    if (!item) {
      // Inside the frame but on no row: the dialog still owns the press, so it
      // cannot fall through to the transcript's selection underneath.
      return event.y >= 0 && event.y < this.renderedRows ? { handled: true } : undefined;
    }
    const index = this.items().findIndex((candidate) => sameItem(candidate, item));
    if (event.type === "move") {
      if (index >= 0 && index !== this.row) {
        this.row = index;
        this.warning = undefined;
        this.tui.requestRender();
      }
      return { handled: true };
    }
    if (event.button !== "left" || (event.type !== "press" && event.type !== "click")) {
      return undefined;
    }
    // Both text rows are fields: a press highlights, and the click that follows
    // opens the field, or places the cursor when it is already open.
    if (item.kind === "custom" || item.kind === "note") {
      const field = item.kind === "note" ? "note" : "answer";
      if (event.type === "press") {
        if (index >= 0) {
          this.row = index;
          this.tui.requestRender();
        }
        return { handled: true, focus: true };
      }
      if (this.editing !== field) {
        this.startEditing(field);
        return { handled: true };
      }
      return this.editingInput.handleMouse?.({ ...event, y: 0 }) ?? { handled: true };
    }
    if (index >= 0) this.row = index;
    if (event.type === "press") {
      if (index >= 0) {
        this.warning = undefined;
        this.tui.requestRender();
      }
      return { handled: true, focus: true };
    }
    this.activate(item);
    return { handled: true };
  }

  render(width: number): string[] {
    const w = Math.max(MIN_WIDTH, Math.min(width, MAX_WIDTH));
    this.hits = new Map();
    this.tabCells = [];
    this.tabRow = -1;
    const budget = Math.max(8, Math.min(this.tui.terminal.rows - RESERVED_ROWS, MAX_BUDGET));

    // What to give up, cheapest loss first: the preview, then the rows above and
    // below the cursor (still reachable by moving it), and the descriptions
    // last. The first frame that fits is the one drawn, so a short terminal
    // hides nothing the keyboard cannot reach.
    const attempts: Attempt[] = [
      { preview: true, window: false, descriptions: "all" },
      { preview: true, window: true, descriptions: "all" },
      { preview: false, window: false, descriptions: "all" },
      { preview: false, window: true, descriptions: "all" },
      // One explanation plus all the labels beats every label and no
      // explanation: the row under the cursor is the one being weighed.
      { preview: false, window: true, descriptions: "highlighted" },
      { preview: false, window: true, descriptions: "highlighted", clip: 2, questionLines: 4 },
      { preview: false, window: true, descriptions: "none", questionLines: 4 },
    ];
    let rows: BodyRow[] = [];
    for (const attempt of attempts) {
      rows = this.buildBody(w, budget, attempt);
      if (rows.length + 2 <= budget) break;
    }

    const inner = w - 2;
    const border = (text: string) => this.theme.fg("borderMuted", text);
    const cell = (text: string) =>
      border("│") + truncateToWidth(text, inner, "…", true) + border("│");
    const title = this.title();
    const hint = truncateToWidth(` ${this.hint()} `, Math.max(0, inner - 1), "…");
    const topFill = Math.max(0, inner - 1 - visibleWidth(title));
    const bottomFill = Math.max(0, inner - 1 - visibleWidth(hint));
    const lines = [
      border("╭─") + title + border("─".repeat(topFill)) + border("╮"),
      ...rows.map((row) => cell(row.text)),
      border(`╰${"─".repeat(bottomFill)}`) + this.theme.fg("dim", hint) + border("─╯"),
    ];
    // Inner row k is drawn at line k + 1, under the top border.
    rows.forEach((row, index) => {
      if (row.hit) this.hits.set(index + 1, row.hit);
    });
    if (this.tabRow >= 0) this.tabRow += 1;
    if (rows.length + 2 > budget) {
      // Nothing left to give up: one row taller than the whole frame, as a
      // single option whose description is longer than the terminal.
      const keep = Math.max(1, budget - 2);
      lines.splice(1 + keep, lines.length - 2 - keep);
    }
    this.renderedRows = lines.length;
    return lines;
  }

  private title(): string {
    const answered = this.drafts.filter(isAnswered).length;
    const label =
      this.tabs.length > 1 ? "Ask questions" : (this.questions[0]?.header ?? "Ask questions");
    const progress = this.tabs.length > 1 ? ` ${answered}/${this.questions.length} answered ` : "";
    return (
      this.theme.fg("accent", this.theme.bold(` ${label} `)) + this.theme.fg("muted", progress)
    );
  }

  private hint(): string {
    if (this.editing !== undefined) return "enter save · esc back";
    if (this.question) {
      const parts = ["↑/↓ move", this.question.multiSelect ? "space toggle" : "enter select"];
      if (this.question.multiSelect) parts.push("enter done");
      if (this.tabs.length > 1) parts.push("tab questions");
      parts.push("n note");
      if (this.questionMaxOffset > 0) parts.push("shift↓ text");
      parts.push("esc cancel");
      return this.warning ? `⚠ ${this.warning}` : parts.join(" · ");
    }
    return this.warning ? `⚠ ${this.warning}` : "enter send · ↑/↓ move · esc cancel";
  }

  /**
   * Where the answer text and the preview go in this frame.
   *
   * The preview takes a column only when the frame is wide enough for the
   * options to stay readable beside it; otherwise it goes under them, where it
   * costs rows instead of columns.
   */
  private layout(inner: number, preview: boolean): Layout {
    const current = this.question?.options[this.row];
    const markdown = preview && current?.preview ? current.preview : undefined;
    if (markdown === undefined) return { inner, textWidth: inner };
    if (inner >= SIDE_BY_SIDE_WIDTH) {
      const left = Math.floor((inner - 3) * 0.52);
      return { inner, textWidth: left, side: Math.max(8, inner - 3 - left), markdown };
    }
    return { inner, textWidth: inner, under: Math.max(8, inner - 4), markdown };
  }

  private buildBody(w: number, budget: number, attempt: Attempt): BodyRow[] {
    const inner = w - 2;
    const rows: BodyRow[] = [];
    const tabs = this.tabBar(inner);
    if (tabs) {
      this.tabRow = rows.length;
      rows.push({ text: tabs });
    }
    const question = this.question;
    if (!question) {
      rows.push({ text: "" });
      rows.push({ text: this.theme.fg("accent", this.theme.bold(" Review your answers")) });
      rows.push({ text: "" });
      rows.push(...this.reviewRows(inner));
      rows.push({ text: "" });
      return rows;
    }
    // The question takes its room first, but not all of it: a long one at a
    // narrow width would otherwise leave nothing for the answers.
    const lines = wrapTextWithAnsi(question.question, Math.max(8, inner - 4));
    const room = Math.max(
      2,
      Math.min(attempt.questionLines ?? Number.MAX_SAFE_INTEGER, budget - 2 - rows.length - 2 - 5),
    );
    this.questionMaxOffset = Math.max(0, lines.length - room);
    this.questionOffset = Math.min(this.questionOffset, this.questionMaxOffset);
    const shown = lines.slice(this.questionOffset, this.questionOffset + room);
    this.questionRows = { start: rows.length, end: rows.length };
    if (this.questionOffset > 0) rows.push({ text: this.theme.fg("dim", "  …") });
    for (const line of shown) rows.push({ text: `  ${this.theme.fg("text", line)}` });
    this.questionRows.end = rows.length;
    if (this.questionOffset + room < lines.length) rows.push({ text: this.theme.fg("dim", "  …") });
    rows.push({ text: "" });
    const layout = this.layout(inner, attempt.preview);
    const capacity = Math.max(1, budget - 2 - rows.length - 1);
    rows.push(...this.itemRows(layout, attempt, capacity));
    rows.push({ text: "" });
    return rows;
  }

  /** The tab strip, when there is more than one tab; records its click cells. */
  private tabBar(inner: number): string | undefined {
    if (this.tabs.length < 2) return undefined;
    // Rebuilt on every layout attempt, so the cells are cleared with the row.
    const chip = (label: (index: number) => string): string => {
      this.tabCells = [];
      const chips: string[] = [];
      let x = 1;
      this.tabs.forEach((tab, index) => {
        const current = index === this.tab;
        const answered = tab.kind === "question" && isAnswered(this.drafts[tab.index]!);
        const plain = ` ${label(index)} `;
        const text = current
          ? this.theme.bg("selectedBg", this.theme.fg("accent", this.theme.bold(plain)))
          : this.theme.fg(answered ? "text" : "muted", plain);
        chips.push(text);
        const width = visibleWidth(plain);
        this.tabCells.push({ start: x, end: x + width, tab: index });
        x += width + 1;
      });
      return chips.join(" ");
    };
    const answered = (index: number) => {
      const tab = this.tabs[index]!;
      return tab.kind === "question" && isAnswered(this.drafts[tab.index]!) ? "✓" : "";
    };
    const full = chip((index) => {
      const tab = this.tabs[index]!;
      const label = tab.kind === "review" ? "Review" : (this.questions[tab.index]?.header ?? "?");
      const mark = answered(index);
      return `${index + 1} ${label}${mark ? ` ${mark}` : ""}`;
    });
    if (visibleWidth(full) <= inner) return full;
    // Too many headers for the width: numbers still name every tab and stay
    // clickable, where clipping would leave the last ones out of reach.
    return chip((index) => `${index + 1}${answered(index)}`);
  }

  private reviewRows(inner: number): BodyRow[] {
    const rows: BodyRow[] = [];
    this.questions.forEach((question, index) => {
      const draft = this.drafts[index]!;
      const item: Item = { kind: "review", question: index };
      const text = draft.text.trim();
      const values = text
        ? [text]
        : draft.picked.flatMap((picked) => {
            const option = question.options[picked];
            return option ? [option.label] : [];
          });
      const answer = values.length > 0 ? values.join(", ") : "not answered";
      const line = `${this.cursor(index)}${this.theme.fg("text", question.header)}  ${this.theme.fg(
        values.length > 0 ? "muted" : "warning",
        truncateToWidth(answer, Math.max(8, inner - 12), "…"),
      )}`;
      const note = this.notes[index]?.trim() ?? "";
      rows.push({ text: line, hit: item });
      if (note) {
        rows.push({
          text: this.theme.fg("dim", `    ${truncateToWidth(note, Math.max(8, inner - 8), "…")}`),
        });
      }
    });
    const send = this.tabs.length - 1;
    rows.push({ text: "" });
    rows.push({ text: this.actionRow(send, "Send"), hit: { kind: "send" } });
    rows.push({ text: this.actionRow(send + 1, "Cancel"), hit: { kind: "cancel" } });
    return rows;
  }

  /**
   * The answer rows, windowed to the highlighted one when they do not all fit.
   *
   * Windowing rather than dropping text: a short terminal then shows fewer rows
   * at a time, and every row stays reachable by moving the cursor, which is the
   * access a scrollbar would have given.
   */
  private itemRows(layout: Layout, attempt: Attempt, capacity: number): BodyRow[] {
    const blocks = this.itemBlocks(layout, attempt);
    if (blocks.length === 0) return [];
    const total = blocks.reduce((sum, block) => sum + block.length, 0);
    if (!attempt.window || total <= capacity) return this.withPreview(blocks.flat(), layout);
    // The two markers cost a row each, so the window leaves them room.
    const limit = Math.max(1, capacity - 2);
    let start = Math.min(this.row, blocks.length - 1);
    let end = start;
    let used = blocks[start]?.length ?? 0;
    for (;;) {
      const below = blocks[end + 1];
      if (below && used + below.length <= limit) {
        used += below.length;
        end += 1;
        continue;
      }
      const above = blocks[start - 1];
      if (above && used + above.length <= limit) {
        used += above.length;
        start -= 1;
        continue;
      }
      break;
    }
    const rows: BodyRow[] = [];
    if (start > 0) rows.push({ text: this.theme.fg("dim", "  ↑") });
    rows.push(...blocks.slice(start, end + 1).flat());
    if (end < blocks.length - 1) rows.push({ text: this.theme.fg("dim", "  ↓") });
    return this.withPreview(rows, layout);
  }

  /** One block of rows per answer row, drawn at the width this layout allows. */
  private itemBlocks(layout: Layout, attempt: Attempt): BodyRow[][] {
    const question = this.question;
    if (!question) return [];
    const draft = this.drafts[this.questionIndex ?? 0]!;
    const textWidth = layout.textWidth;
    return this.items().map((item, index) => {
      const at = index === this.row;
      const cursor = at ? this.theme.fg("accent", "▸ ") : "  ";
      switch (item.kind) {
        case "option": {
          const option = question.options[item.index]!;
          const picked = draft.picked.includes(item.index);
          const box = question.multiSelect ? (picked ? "■" : "□") : picked ? "●" : "○";
          const label = wrapTextWithAnsi(
            `${item.index + 1}  ${option.label}`,
            Math.max(8, textWidth - 4),
          );
          // Wrapped, not clipped: the label is the row, and a cut-off label is
          // an option the user cannot recognise.
          const rows: BodyRow[] = label.map((line, lineIndex) => {
            const text =
              lineIndex === 0 ? `${cursor}${box} ${line}` : `    ${this.theme.fg("text", line)}`;
            return {
              text: at && lineIndex === 0 ? this.theme.bold(this.theme.fg("accent", text)) : text,
              hit: item,
            };
          });
          const explains =
            attempt.descriptions === "all" || (attempt.descriptions === "highlighted" && at);
          if (option.description && explains) {
            const lines = wrapTextWithAnsi(option.description, Math.max(8, textWidth - 6));
            const limit = at && attempt.clip !== undefined ? attempt.clip : lines.length;
            for (const line of lines.slice(0, limit)) {
              rows.push({ text: `      ${this.theme.fg("muted", line)}`, hit: item });
            }
            if (limit < lines.length) {
              rows.push({ text: `      ${this.theme.fg("dim", "…")}`, hit: item });
            }
          }
          return rows;
        }
        case "custom": {
          if (at && this.editing) {
            return [
              {
                text: `  ${this.input.render(Math.max(8, textWidth - 4))[0] ?? ""}`,
                hit: item,
              },
            ];
          }
          const typed = draft.text.trim();
          const label = wrapTextWithAnsi(typed || TYPE_SOMETHING, Math.max(8, textWidth - 6));
          const rows: BodyRow[] = label.map((line, lineIndex) => ({
            text:
              lineIndex === 0
                ? `${cursor}${this.theme.fg("muted", "✎ ")}${this.theme.fg(at ? "accent" : "text", line)}`
                : `      ${this.theme.fg(at ? "accent" : "text", line)}`,
            hit: item,
          }));
          return rows;
        }
        case "note": {
          if (at && this.editing === "note") {
            return [
              {
                text: `  ${this.noteInput.render(Math.max(8, textWidth - 4))[0] ?? ""}`,
                hit: item,
              },
            ];
          }
          const note = this.notes[this.questionIndex ?? 0]?.trim() ?? "";
          const lines = wrapTextWithAnsi(
            note ? `Note: ${note}` : "Add a note (n).",
            Math.max(8, textWidth - 6),
          );
          return lines.map((line, lineIndex) => ({
            text:
              lineIndex === 0
                ? `${cursor}${this.theme.fg("muted", "✎ ")}${this.theme.fg(
                    at ? "accent" : note ? "text" : "muted",
                    line,
                  )}`
                : `      ${this.theme.fg("muted", line)}`,
            hit: item,
          }));
        }
        case "done":
          return [{ text: this.actionRow(index, "Done"), hit: item }];
        default:
          return [];
      }
    });
  }

  /** Compose the preview into the rows the answer list produced. */
  private withPreview(rows: BodyRow[], layout: Layout): BodyRow[] {
    if (layout.markdown === undefined) return rows;
    if (layout.side !== undefined) {
      const preview = this.previewRows(layout.markdown, layout.side, PREVIEW_ROWS);
      const height = Math.max(rows.length, preview.length);
      const merged: BodyRow[] = [];
      for (let line = 0; line < height; line += 1) {
        const source = rows[line];
        const text =
          column(source?.text ?? "", layout.textWidth) +
          this.theme.fg("borderMuted", " │ ") +
          column(preview[line] ?? "", layout.side);
        merged.push(source?.hit ? { text, hit: source.hit } : { text });
      }
      return merged;
    }
    // Under the options, and capped: a preview that crowded the answers out
    // would be a preview of the wrong thing.
    const preview = this.previewRows(
      layout.markdown,
      layout.under ?? layout.inner - 4,
      UNDER_PREVIEW_ROWS,
    );
    rows.push({ text: "" });
    rows.push({ text: this.theme.fg("muted", " Preview") });
    for (const line of preview) rows.push({ text: ` ${line}` });
    return rows;
  }

  /** A markdown preview as rows, capped and marked when it was cut. */
  private previewRows(markdown: string, width: number, max: number): string[] {
    const rendered = new Markdown(markdown, 0, 0, getMarkdownTheme()).render(Math.max(8, width));
    if (rendered.length <= max) return rendered;
    const hidden = rendered.length - (max - 1);
    return [
      ...rendered.slice(0, Math.max(1, max - 1)),
      this.theme.fg("dim", `✂ ${hidden} lines hidden`),
    ];
  }

  private cursor(index: number): string {
    return index === this.row ? this.theme.fg("accent", "▸ ") : "  ";
  }

  private actionRow(index: number, label: string): string {
    const at = index === this.row;
    return `${this.cursor(index)}${at ? this.theme.bold(this.theme.fg("accent", label)) : this.theme.fg("text", label)}`;
  }
}

/** Two items are the same target when they name the same thing. */
function sameItem(left: Item, right: Item): boolean {
  if (left.kind !== right.kind) return false;
  if (left.kind === "option" && right.kind === "option") return left.index === right.index;
  if (left.kind === "review" && right.kind === "review") return left.question === right.question;
  return true;
}
