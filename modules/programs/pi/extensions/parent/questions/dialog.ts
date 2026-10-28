/**
 * The questionnaire: one tab per question, a review tab when there is more
 * than one, and the pointer wired to the same actions as the keys.
 *
 * Sizing is layout rather than taste. A question with four described options
 * does not fit a twenty-row terminal alongside a preview pane, so the frame is
 * built three ways — descriptions, then clipped, then without the preview — and
 * the first that fits the row budget is drawn. Options are few enough that
 * windowing them would cost more than it explains.
 *
 * Geometry never depends on which row is highlighted: the preview keeps its
 * rows even for an option without a preview, and no row gains or loses a line
 * under the cursor. Moving the highlight changes what is drawn inside the frame,
 * never the frame itself, so the rows do not jump under the pointer.
 *
 * The preview is a bordered box that hugs what is inside it, so a two-line
 * preview is a small box rather than a mostly empty one, and scrolls within
 * itself, with the position in its own bottom border.
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

/** Below this the frame cannot lay out a question at all; above, it takes the width it is given. */
const MIN_WIDTH = 28;
/** Below this the preview sits under the options instead of beside them. */
const SIDE_BY_SIDE_WIDTH = 88;
/** Columns between the answer column and the preview box when they sit beside each other. */
const COLUMN_GAP = 2;
/**
 * Rows kept for the transcript and footer above and below the frame. The
 * budget is a share of the terminal rather than a constant, so a tall terminal
 * shows more of the question instead of more empty space.
 */
const RESERVED_ROWS = 10;
const MAX_BUDGET = 24;
/**
 * Ceiling on the preview box's rows, borders included. A preview is a glance at
 * an option, not a document to read; the terminal's own budgets are applied on
 * top, so this only bites on a very tall window.
 */
const MAX_BOX_ROWS_SIDE = 20;
const MAX_BOX_ROWS_STACKED = 15;
/** Narrowest box worth drawing: top border, one content row, bottom border. */
const MIN_BOX_ROWS = 3;
/** Floor for the box's content area, so a two-word preview is not a sliver. */
const BOX_MIN_CONTENT_WIDTH = 40;
/** One column of padding inside each border column. */
const BOX_PADDING = 1;
/** Two border columns plus the padding inside each of them. */
const BOX_CHROME = 2 + 2 * BOX_PADDING;
/** Shown in the box when the highlighted option carries no preview of its own. */
const NO_PREVIEW_TEXT = "No preview available";

/** What the frame gives up when the whole of it does not fit. */
interface Attempt {
  preview: boolean;
  window: boolean;
  /** Which rows explain themselves: all of them, or none. */
  descriptions: "all" | "none";
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
  /**
   * Rows the box may use in this frame, borders included. Fixed per question, so
   * hovering from an option with a preview to one without cannot resize the
   * frame or move the rows above it.
   */
  paneRows: number;
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
  /**
   * Columns from the row's start that belong to the target. The pointer has to
   * be over the row's own text, not merely on its line: the rest of the line is
   * dialog space, and hovering it must not move the cursor.
   */
  hitTo?: number;
}

const isAnswered = (draft: Draft) => draft.picked.length > 0 || draft.text.trim() !== "";

/** A row that carries a pointer target over the text it actually draws. */
function target(text: string, item: Item): BodyRow {
  return { text, hit: item, hitTo: visibleWidth(text.replace(/\s+$/, "")) };
}

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
  /** Esc asks once before it throws the answers away; this is that question being pending. */
  private confirming = false;
  /**
   * How far the preview is scrolled, how far it can go, and which row it belongs to.
   * The box prints the position; these are what the keys and the wheel move.
   */
  private previewOffset = 0;
  private previewMax = 0;
  private previewFor: number | undefined;
  /**
   * Tallest box this question can ask for at a given content width, measured
   * once per frame: it is the same for every layout attempt, and measuring it
   * renders every option's markdown.
   */
  private tallestBox: { key: string; rows: number } | undefined;
  /** Where this frame drew the preview, in body rows, for the wheel to hit-test. */
  private previewCells: { top: number; bottom: number; left: number } | undefined;
  private closed = false;
  private isFocused = false;
  private hits = new Map<number, { item: Item; to: number }>();
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
    this.input = new Input({ prompt: "", placeholder: "Your answer" });
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
    const items = this.items();
    if (items.length === 0) return;
    // The note row is not a target: it is reached with `n` alone, so an arrow
    // key never lands on a row whose only action is opening a field.
    let next = this.row;
    for (let attempt = 0; attempt < items.length; attempt += 1) {
      next = (((next + step) % items.length) + items.length) % items.length;
      if (items[next]!.kind !== "note") break;
    }
    this.row = next;
    this.warning = undefined;
    this.tui.requestRender();
  }

  private goTab(tab: number): void {
    this.keepDraft();
    this.questionOffset = 0;
    this.tab = Math.max(0, Math.min(tab, this.tabs.length - 1));
    // The review tab exists to be sent, so enter offers to send it rather than
    // to walk back into a question the user has already answered.
    this.row = Math.max(
      0,
      this.tabKind.kind === "review" ? this.items().findIndex((item) => item.kind === "send") : 0,
    );
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

  private scrollPreview(step: number): void {
    const next = Math.max(0, Math.min(this.previewMax, this.previewOffset + step));
    if (next === this.previewOffset) return;
    this.previewOffset = next;
    this.tui.requestRender();
  }

  /**
   * Scroll whatever the frame had to clip.
   *
   * One key for both regions, because in a frame this wide the question
   * practically always fits and the preview practically never does: the pane
   * wins when it can move, and the question text is the only thing left.
   */
  private scrollClipped(step: number): void {
    if (this.previewMax > 0) this.scrollPreview(step);
    else this.scrollQuestion(step);
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
    // A typed answer joins the picks of a multi-select question instead of
    // replacing them, and does not carry the user off a tab whose answer the
    // Done row still has to confirm.
    const keepPicks = this.question?.multiSelect === true;
    this.drafts[index] = keepPicks
      ? { picked: this.drafts[index]!.picked, text }
      : { picked: [], text };
    this.editing = undefined;
    this.input.focused = false;
    if (keepPicks) {
      this.warning = undefined;
      this.tui.requestRender();
      return;
    }
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
      // Toggling an option says nothing about the answer typed in the row below.
      this.drafts[at] = { picked, text: draft.text };
      this.warning = undefined;
      this.tui.requestRender();
      return;
    }
    this.drafts[at] = { picked: [index], text: "" };
    this.advance();
  }

  /** The answers one question contributes, options first and a typed one last. */
  private valuesOf(index: number): string[] {
    const draft = this.drafts[index]!;
    const options = this.questions[index]!.options;
    const text = draft.text.trim();
    return [
      ...draft.picked.flatMap((picked) => {
        const option = options[picked];
        return option ? [option.label] : [];
      }),
      ...(text ? [text] : []),
    ];
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
      const values = this.valuesOf(index);
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

  /** Esc asks once: an accidental key must not throw away the answers already given. */
  private askCancel(): void {
    this.confirming = true;
    this.warning = "Cancel without answering? enter yes · esc no";
    this.tui.requestRender();
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
    if (this.confirming) {
      // Enter is the answer to the question on the hint line; anything else,
      // esc included, is the user saying they did not mean it.
      if (matchesKey(data, Key.enter)) this.cancel();
      else {
        this.confirming = false;
        this.warning = undefined;
        this.tui.requestRender();
      }
      return;
    }
    // Ctrl+C stays an immediate cancel: it is the key for "stop", not "ask".
    if (matchesKey(data, "ctrl+c")) {
      this.cancel();
      return;
    }
    if (matchesKey(data, Key.escape)) {
      this.askCancel();
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
      this.scrollClipped(matchesKey(data, Key.shift("down")) ? 3 : -3);
      return;
    }
    if (data === "n" && this.question) {
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
    // A digit picks the row it numbers, the way the row prints it. The row for
    // an answer the options do not cover is numbered last, with the rest.
    const digit = /^[1-9]$/.test(data) ? Number(data) - 1 : -1;
    const item = digit >= 0 ? this.items()[digit] : undefined;
    if (item && (item.kind === "option" || item.kind === "custom")) {
      this.row = digit;
      this.activate(item);
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

  /**
   * The target under the pointer: the row under it, when the pointer is over
   * that row's own text rather than the empty part of its line.
   */
  private itemAt(x: number, row: number): Item | undefined {
    const hit = this.hits.get(row);
    return hit && x < hit.to ? hit.item : undefined;
  }

  handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    // Zero-based from the frame's top border, so a body row is `event.y - 1`.
    const row = event.y - 1;
    const x = event.x - 1;
    if (event.type === "wheel" && event.wheelDelta) {
      const step = event.wheelDelta < 0 ? -1 : 1;
      const pane = this.previewCells;
      // A pane with nothing to scroll is not a scroll target: the wheel keeps
      // doing what it does everywhere else.
      if (this.previewMax > 0 && pane && row >= pane.top && row < pane.bottom && x >= pane.left) {
        this.scrollPreview(step);
        return { handled: true };
      }
      const overText = row >= this.questionRows.start && row < this.questionRows.end;
      if (overText && this.questionMaxOffset > 0) {
        this.scrollQuestion(step);
        return { handled: true };
      }
      this.move(step);
      return { handled: true };
    }
    // A tab row is a strip of chips, so it hit-tests by column, not by row.
    if (row === this.tabRow) {
      const cell = this.tabCells.find((candidate) => x >= candidate.start && x < candidate.end);
      if (!cell) return undefined;
      if (event.type === "press") return { handled: true, focus: true };
      if (event.type === "click") {
        this.goTab(cell.tab);
        return { handled: true };
      }
      return undefined;
    }
    const item = this.itemAt(x, row);
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
    const w = Math.max(MIN_WIDTH, width);
    this.hits = new Map();
    this.tabCells = [];
    this.tabRow = -1;
    this.tallestBox = undefined;
    const budget = Math.max(8, Math.min(this.tui.terminal.rows - RESERVED_ROWS, MAX_BUDGET));

    // What to give up, cheapest loss first: the preview, then the rows above and
    // below the cursor (still reachable by moving it), then the descriptions.
    // Which row is highlighted never enters into it: the geometry has to be the
    // same whichever row the pointer is on, or the frame jumps under it.
    const attempts: Attempt[] = [
      { preview: true, window: false, descriptions: "all" },
      { preview: true, window: true, descriptions: "all" },
      { preview: false, window: false, descriptions: "all" },
      { preview: false, window: true, descriptions: "all" },
      { preview: false, window: true, descriptions: "all", clip: 2, questionLines: 4 },
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
    rows.forEach((row, index) => {
      if (row.hit) this.hits.set(index, { item: row.hit, to: row.hitTo ?? inner });
    });
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
      if (this.previewMax > 0) parts.push("shift↓ preview");
      else if (this.questionMaxOffset > 0) parts.push("shift↓ text");
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
   * costs rows instead of columns. Once a question has a preview anywhere, the
   * pane is on screen for every row of it — a pane that vanished under one row
   * and reappeared under the next would reflow the list on every mousemove.
   */
  private layout(inner: number, preview: boolean, spare: number): Layout {
    const options = this.question?.options ?? [];
    const markdown = preview ? options[this.row]?.preview : undefined;
    const anyPreview = preview && options.some((option) => option.preview !== undefined);
    if (!anyPreview) return { inner, textWidth: inner, paneRows: 0 };
    // Scrolling belongs to the row it was scrolled on, not to the pane.
    const showing = markdown === undefined ? -1 : this.row;
    if (showing !== this.previewFor) {
      this.previewFor = showing;
      this.previewOffset = 0;
    }
    const sideBySide = inner >= SIDE_BY_SIDE_WIDTH;
    const column = sideBySide
      ? Math.max(BOX_CHROME + 8, inner - COLUMN_GAP - Math.floor((inner - COLUMN_GAP) * 0.52))
      : Math.max(BOX_CHROME + 8, inner - 4);
    // The pane is as tall as the tallest box it may have to draw, capped by the
    // layout's ceiling and by the rows the frame has left, so hovering never
    // changes the pane's height partway through a question.
    const contentWidth = Math.max(8, column - BOX_CHROME);
    const key = `${this.tab}:${contentWidth}`;
    if (this.tallestBox?.key !== key) {
      const rows = options.reduce(
        (max, option) => Math.max(max, this.previewContent(option.preview, contentWidth).length),
        0,
      );
      this.tallestBox = { key, rows };
    }
    const tallest = this.tallestBox.rows;
    const ceiling = sideBySide ? MAX_BOX_ROWS_SIDE : MAX_BOX_ROWS_STACKED;
    // The pane's appetite: as tall as its tallest preview asks for, within the
    // layout's ceiling. Side by side it also has to fit the rows left in the
    // frame; under the options the list is measured first and the box takes
    // what is left over (see `buildBody`).
    const room = sideBySide ? spare : spare - 1 - MIN_BOX_ROWS;
    const paneRows = Math.max(MIN_BOX_ROWS, Math.min(ceiling, room, tallest + 2));
    if (sideBySide) {
      const left = Math.floor((inner - COLUMN_GAP) * 0.52);
      return {
        inner,
        textWidth: left,
        side: Math.max(BOX_CHROME + 8, inner - COLUMN_GAP - left),
        paneRows,
        ...(markdown === undefined ? {} : { markdown }),
      };
    }
    return {
      inner,
      textWidth: inner,
      under: Math.max(BOX_CHROME + 8, inner - 4),
      paneRows,
      ...(markdown === undefined ? {} : { markdown }),
    };
  }

  private buildBody(w: number, budget: number, attempt: Attempt): BodyRow[] {
    const inner = w - 2;
    const rows: BodyRow[] = [];
    // Each attempt starts from no pane: an attempt that draws one must not leave
    // its scroll state behind for the attempt that fits without it.
    this.previewCells = undefined;
    this.previewMax = 0;
    const tabs = this.tabBar(inner);
    if (tabs) {
      this.tabRow = rows.length;
      rows.push({ text: tabs });
      // A tab strip is chrome; the question starts a line below it.
      rows.push({ text: "" });
    }
    const question = this.question;
    if (!question) {
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
    // The pane may take the whole budget that is left; the box decides how much
    // of it it wants, and the frame is the same whichever row is highlighted.
    const spare = Math.max(1, budget - 2 - rows.length - 1);
    const layout = this.layout(inner, attempt.preview, spare);
    const blocks = this.itemBlocks(layout, attempt);
    const listRows = blocks.reduce((sum, block) => sum + block.length, 0);
    if (layout.under !== undefined) {
      // Under the options the box and the list spend the same rows. It only
      // appears when the list does not have to shrink for it: a preview that
      // hides the options it describes is worse than no preview, so this frame
      // falls through to an attempt without one.
      const alone = spare - 1 - listRows;
      if (alone < MIN_BOX_ROWS) {
        layout.under = undefined;
        layout.paneRows = 0;
      } else {
        layout.paneRows = Math.max(MIN_BOX_ROWS, Math.min(MAX_BOX_ROWS_STACKED, alone));
      }
    }
    // A box under the options costs rows the answer list cannot have, so the
    // list is windowed to what is left instead of pushing the box off the frame.
    const paneCost = layout.under === undefined ? 0 : layout.paneRows + 1;
    const capacity = Math.max(1, budget - 2 - rows.length - 1 - paneCost);
    rows.push(...this.itemRows(layout, attempt, capacity, rows.length, blocks));
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
      const item: Item = { kind: "review", question: index };
      const values = this.valuesOf(index);
      const answer = values.length > 0 ? values.join(", ") : "not answered";
      const line = `${this.cursor(index)}${this.theme.fg("text", question.header)}  ${this.theme.fg(
        values.length > 0 ? "muted" : "warning",
        truncateToWidth(answer, Math.max(8, inner - 12), "…"),
      )}`;
      const note = this.notes[index]?.trim() ?? "";
      rows.push(target(line, item));
      if (note) {
        rows.push({
          text: this.theme.fg("dim", `    ${truncateToWidth(note, Math.max(8, inner - 8), "…")}`),
        });
      }
    });
    const send = this.tabs.length - 1;
    rows.push({ text: "" });
    rows.push(target(this.actionRow(send, "Send"), { kind: "send" }));
    rows.push(target(this.actionRow(send + 1, "Cancel"), { kind: "cancel" }));
    return rows;
  }

  /**
   * The answer rows, windowed to the highlighted one when they do not all fit.
   *
   * Windowing rather than dropping text: a short terminal then shows fewer rows
   * at a time, and every row stays reachable by moving the cursor, which is the
   * access a scrollbar would have given.
   */
  private itemRows(
    layout: Layout,
    attempt: Attempt,
    capacity: number,
    base: number,
    blocks: BodyRow[][],
  ): BodyRow[] {
    if (blocks.length === 0) return [];
    const total = blocks.reduce((sum, block) => sum + block.length, 0);
    if (!attempt.window || total <= capacity) {
      return this.withPreview(blocks.flat(), layout, base);
    }
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
    // Pad the window to the rows it was given: which blocks fit depends on where
    // the cursor is, and a list that ends short of its allowance would move the
    // frame every time the pointer crossed a taller row.
    while (rows.length < capacity) rows.push({ text: "" });
    return this.withPreview(rows, layout, base);
  }

  /** One block of rows per answer row, drawn at the width this layout allows. */
  private itemBlocks(layout: Layout, attempt: Attempt): BodyRow[][] {
    const question = this.question;
    if (!question) return [];
    const draft = this.drafts[this.questionIndex ?? 0]!;
    const textWidth = layout.textWidth;
    // Every row hangs its wrapped tail and its description off the same column
    // as its label, so a row reads as one block rather than three starts.
    const labelColumn = 4 + String(question.options.length + 1).length + 2;
    const hang = " ".repeat(labelColumn);
    const wrapWidth = Math.max(8, textWidth - labelColumn);
    return this.items().map((item, index) => {
      const at = index === this.row;
      const cursor = at ? this.theme.fg("accent", "▸ ") : "  ";
      switch (item.kind) {
        case "option": {
          const option = question.options[item.index]!;
          const picked = draft.picked.includes(item.index);
          const box = question.multiSelect ? (picked ? "■" : "□") : picked ? "●" : "○";
          // Wrapped, not clipped: the label is the row, and a cut-off label is
          // an option the user cannot recognise.
          const label = wrapTextWithAnsi(option.label, wrapWidth);
          const rows: BodyRow[] = label.map((line, lineIndex) => {
            const text =
              lineIndex === 0
                ? `${cursor}${box} ${item.index + 1}  ${line}`
                : `${hang}${this.theme.fg("text", line)}`;
            return target(
              at && lineIndex === 0 ? this.theme.bold(this.theme.fg("accent", text)) : text,
              item,
            );
          });
          if (option.description && attempt.descriptions === "all") {
            const lines = wrapTextWithAnsi(option.description, wrapWidth);
            // Clipping applies to every row, not just the highlighted one: a
            // row that grows under the pointer moves everything below it.
            const limit = attempt.clip ?? lines.length;
            for (const line of lines.slice(0, limit)) {
              rows.push(target(`${hang}${this.theme.fg("muted", line)}`, item));
            }
            if (limit < lines.length) {
              rows.push(target(`${hang}${this.theme.fg("dim", "…")}`, item));
            }
          }
          return rows;
        }
        case "custom": {
          // The field stays open in place while the pointer wanders: moving the
          // mouse off a half-typed answer is not a decision to close it.
          const typing = this.editing === "answer";
          const typed = draft.text.trim();
          const number = question.options.length + 1;
          // The same orb or checkbox as an option, filled once there is an answer
          // in it, so the row takes part in the list it belongs to.
          const filled = typing ? this.input.getValue().trim() !== "" : typed !== "";
          const box = question.multiSelect ? (filled ? "■" : "□") : filled ? "●" : "○";
          if (typing) {
            const field = this.input.render(Math.max(8, wrapWidth))[0] ?? "";
            return [target(`${cursor}${box} ${number}  ${field}`, item)];
          }
          // Only the invitation is dim: the orb is the same one an option wears,
          // and dimming it would make the row look disabled rather than empty.
          const tone = typed ? (at ? "accent" : "text") : "dim";
          const label = wrapTextWithAnsi(typed || TYPE_SOMETHING, wrapWidth);
          return label.map((line, lineIndex) =>
            target(
              lineIndex === 0
                ? `${cursor}${box} ${number}  ${this.theme.fg(tone, line)}`
                : `${hang}${this.theme.fg(tone, line)}`,
              item,
            ),
          );
        }
        case "note": {
          // Set apart from the answers by a blank row and reachable only with
          // `n`: nothing here is a choice, so it is not a row the cursor lands
          // on, and it carries no hit target for the pointer either.
          const note = this.notes[this.questionIndex ?? 0]?.trim() ?? "";
          const rows: BodyRow[] = [{ text: "" }];
          if (this.editing === "note") {
            rows.push({ text: `  ${this.noteInput.render(Math.max(8, textWidth - 4))[0] ?? ""}` });
            return rows;
          }
          const lines = wrapTextWithAnsi(
            note ? `Note: ${note}` : "Add a note (n).",
            Math.max(8, textWidth - 4),
          );
          const hintLines = lines.map((line, lineIndex) => ({
            text:
              lineIndex === 0
                ? `  ${this.theme.fg("muted", "✎ ")}${this.theme.fg(note ? "text" : "muted", line)}`
                : `    ${this.theme.fg("muted", line)}`,
          }));
          return [...rows, ...hintLines];
        }
        case "done":
          // An action rather than an answer, and set apart from the row above.
          return [{ text: "" }, target(this.actionRow(index, "Done"), item)];
        default:
          return [];
      }
    });
  }

  /** Compose the preview box into the rows the answer list produced. */
  private withPreview(rows: BodyRow[], layout: Layout, base: number): BodyRow[] {
    if (layout.side === undefined && layout.under === undefined) return rows;
    if (layout.side !== undefined) {
      const box = this.previewBox(layout.markdown, layout.side, layout.paneRows);
      // The pane keeps the rows it was given, not the rows the box happened to
      // need: a short preview must not shrink the frame above it.
      // The box needs no divider beside it: it is already a frame, and a rule
      // down the middle of the dialog only competes with it.
      const height = Math.max(rows.length, layout.paneRows);
      const merged: BodyRow[] = [];
      for (let line = 0; line < height; line += 1) {
        const source = rows[line];
        const text =
          column(source?.text ?? "", layout.textWidth) +
          " ".repeat(COLUMN_GAP) +
          column(box[line] ?? "", layout.side);
        merged.push(source?.hit ? { text, hit: source.hit, hitTo: source.hitTo } : { text });
      }
      this.previewCells = {
        top: base,
        bottom: base + layout.paneRows,
        left: layout.textWidth + COLUMN_GAP,
      };
      return merged;
    }
    // Under the options, and capped: a preview that crowded the answers out
    // would be a preview of the wrong thing. The pane keeps its rows here too,
    // for the same reason as above.
    const box = this.previewBox(layout.markdown, layout.under ?? layout.inner - 4, layout.paneRows);
    rows.push({ text: "" });
    const top = base + rows.length;
    // One column of air, so the box lines up with the option text above it
    // rather than with the frame's own edge.
    for (const line of box) rows.push({ text: ` ${line}` });
    for (let line = box.length; line < layout.paneRows; line += 1) rows.push({ text: "" });
    this.previewCells = { top, bottom: top + box.length, left: 0 };
    return rows;
  }

  /** A preview's markdown as rows at the given content width, or the placeholder. */
  private previewContent(markdown: string | undefined, width: number): string[] {
    if (markdown === undefined) return [this.theme.fg("dim", NO_PREVIEW_TEXT)];
    return stripFenceMarkers(
      new Markdown(markdown, 0, 0, getMarkdownTheme()).render(Math.max(8, width)),
    );
  }

  /**
   * The preview as a bordered box, at most `maxRows` tall.
   *
   * The box hugs what is inside it: its width follows the widest row, and its
   * height the number of rows, so a two-line preview is a small box rather than
   * a mostly empty one. What still does not fit scrolls, and the bottom border
   * carries the position, which keeps the box closed whether it is cut or not.
   */
  private previewBox(markdown: string | undefined, maxWidth: number, maxRows: number): string[] {
    const innerMax = Math.max(8, maxWidth - BOX_CHROME);
    const rendered = this.previewContent(markdown, innerMax);
    const contentRows = Math.max(1, Math.min(rendered.length, maxRows - 2));
    this.previewMax = Math.max(0, rendered.length - contentRows);
    this.previewOffset = Math.min(this.previewOffset, this.previewMax);
    const content = rendered.slice(this.previewOffset, this.previewOffset + contentRows);
    // Markdown pads every row to the width it was given, so measuring the raw
    // rows would make every box full width; it hugs the trimmed width instead.
    const widest = content.reduce(
      (max, line) => Math.max(max, visibleWidth(line.replace(/\s+$/, ""))),
      0,
    );
    const inner = Math.min(innerMax, Math.max(Math.min(BOX_MIN_CONTENT_WIDTH, innerMax), widest));
    const dashSpan = inner + 2 * BOX_PADDING;
    const paint = (text: string) => this.theme.fg("accent", text);
    const pad = " ".repeat(BOX_PADDING);
    const lines = [paint(`┌${"─".repeat(dashSpan)}┐`)];
    for (const line of content) {
      // No ellipsis: the only rows wider than `inner` are padding, never text.
      lines.push(`${paint("│")}${pad}${truncateToWidth(line, inner, "", true)}${pad}${paint("│")}`);
    }
    const total = this.previewMax + contentRows;
    const marker =
      this.previewMax === 0
        ? ""
        : ` ✂ ${this.previewOffset + 1}-${this.previewOffset + contentRows} of ${total} `;
    lines.push(paint(`└${borderRun(dashSpan, marker)}┘`));
    return lines;
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

const ANSI_SGR_RE = /\u001b\[[0-9;]*m/g;
const ANSI_OSC8_RE = /\u001b\]8;[^\u0007\u001b]*(?:\u0007|\u001b\\)/g;
const FENCE_MARKER_RE = /^`{3}/;

/**
 * Drop fenced-code-block marker rows, which pi-tui's markdown renders as rows
 * of their own: inside a box they read as content instead of as punctuation.
 * Inline code is unaffected — the renderer already emits it without backticks.
 */
function stripFenceMarkers(lines: readonly string[]): string[] {
  return lines.filter((line) => {
    const clean = line.replace(ANSI_SGR_RE, "").replace(ANSI_OSC8_RE, "");
    return !FENCE_MARKER_RE.test(clean);
  });
}

/** A run of `span` dashes with `marker` centred in it, or plain dashes if it will not fit. */
function borderRun(span: number, marker: string): string {
  if (marker === "" || marker.length >= span) return "─".repeat(span);
  const left = Math.floor((span - marker.length) / 2);
  return "─".repeat(left) + marker + "─".repeat(span - marker.length - left);
}
