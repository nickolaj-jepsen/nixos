/**
 * The approval page (C5, D13): before the run, the owner sees what will be built
 * and changed, the steps, the gates and every point the run may stop, and
 * changes the mode, the run's settings, item tiers and open-question answers
 * there.
 *
 * The content and the rewrites are `approval-view.ts`; this file is the pi side:
 * the overlay, its keys, the writes the edits land as, and the dialogs a host
 * without a terminal gets. A parse failure never reaches here — the conductor
 * refuses approval first (D10).
 */
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext, Theme } from "@earendil-works/pi-coding-agent";
import {
  type Component,
  Input,
  Key,
  matchesKey,
  truncateToWidth,
  wrapTextWithAnsi,
} from "@earendil-works/pi-tui";
import {
  amendmentEntries,
  appendAmendments,
  applyPage,
  approvalBlocks,
  approvalMarkdown,
  type ApprovalBlock,
  type ApprovalRow,
  initialPage,
  type PageState,
  rewriteTiers,
  tierEdits,
  today,
} from "./approval-view.ts";
import {
  type Approval,
  type Flow,
  type JudgeHandoffVerdict,
  LEVELS,
  type Mode,
  MODES,
  type ParsedHandoff,
  type ResolvedSettings,
} from "./contracts.ts";
import { readText, reportLine, settingsOf, writeFlow } from "./state.ts";

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

/** The three things the page can answer (C5). */
type PageDecision = { kind: "approve" } | { kind: "back"; note: string } | { kind: "cancel" };

/** A decision, and the state the page left behind so approving applies the edits. */
type PageResult = PageDecision & { page: PageState };

/** What the page draws from: the plan, the flow it belongs to, and the settings it runs on. */
type PageSource = { flow: Flow; handoff: ParsedHandoff; settings: ResolvedSettings };

/** The part of pi's TUI the page reads, so a test can stand in for the terminal. */
export type ApprovalViewport = { rows: number; requestRender(): void };

/** Rows the transcript and the editor above and below the overlay keep. */
const RESERVED_ROWS = 8;

/** The keys that jump straight to a row, so a long plan does not have to be walked. */
const JUMPS: Record<string, (row: ApprovalRow) => boolean> = {
  m: (row) => row.kind === "mode",
  r: (row) => row.kind === "setting" && row.key === "run",
  f: (row) => row.kind === "setting" && row.key === "finalReview",
  t: (row) => row.kind === "tier",
  q: (row) => row.kind === "question",
  a: (row) => row.kind === "approve",
  s: (row) => row.kind === "back",
};

const sameRow = (left: ApprovalRow, right: ApprovalRow): boolean =>
  left.kind === right.kind &&
  ("id" in left ? left.id === ("id" in right ? right.id : undefined) : !("id" in right)) &&
  ("key" in left ? left.key === ("key" in right ? right.key : undefined) : !("key" in right));

/**
 * The page as an overlay: one scrolling document of the plan, with the rows the
 * owner changes drawn in place and the actions at the end. Enter approves on the
 * row it opens on (the run's default), so an owner who read the handoff approves
 * with one key; everything else is edited before that.
 */
export class ApprovalOverlay implements Component {
  private readonly viewport: ApprovalViewport;
  private readonly theme: Theme;
  private readonly source: PageSource;
  private readonly done: (result: PageResult) => void;
  /** The owner's edits so far; approving applies them. */
  private readonly page: PageState;
  /** The page as it opened, so approving can tell the owner's edits from the defaults. */
  private readonly opened: PageState;
  private focus = 0;
  private editing: { row: ApprovalRow; input: Input } | undefined;
  private warning: string | undefined;
  private offset = 0;
  /**
   * How the next frame settles the scroll: `top` leaves the page at its first
   * line, which is where it opens and is read; `follow` moves it just far enough
   * to keep the cursor on screen; `recenter` brings a jumped-to row into the
   * middle third, so what comes after it is visible too.
   */
  private scroll: "top" | "follow" | "recenter" = "top";
  private closed = false;

  constructor(
    viewport: ApprovalViewport,
    theme: Theme,
    source: PageSource,
    page: PageState,
    done: (result: PageResult) => void,
  ) {
    this.viewport = viewport;
    this.theme = theme;
    this.source = source;
    this.page = page;
    this.opened = structuredClone(page);
    this.done = done;
    const approved = this.rows().findIndex((row) => row.kind === "approve");
    this.focus = approved >= 0 ? approved : 0;
  }

  /** Nothing is cached between frames: the page changes under every keystroke. */
  invalidate(): void {
    this.viewport.requestRender();
  }

  handleInput(data: string): void {
    if (this.closed) return;
    try {
      this.input(data);
    } catch (error) {
      // A throw out of a component's handler ends pi, so the page keeps the failure.
      this.warning = `the page could not act on that: ${message(error)}`;
      this.viewport.requestRender();
    }
  }

  private input(data: string): void {
    if (this.editing) {
      this.editing.input.handleInput(data);
      this.viewport.requestRender();
      return;
    }
    if (matchesKey(data, Key.escape)) {
      this.finish({ kind: "cancel" });
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
    if (matchesKey(data, Key.left) || data === "-") {
      this.change(-1);
      return;
    }
    if (matchesKey(data, Key.right) || data === "+") {
      this.change(1);
      return;
    }
    if (matchesKey(data, Key.enter)) {
      this.activate();
      return;
    }
    const jump = JUMPS[data];
    if (jump) {
      const rows = this.rows();
      const at = rows.findIndex(jump);
      if (at >= 0) this.focus = at;
      this.scroll = "recenter";
      this.warning = undefined;
      this.viewport.requestRender();
    }
  }

  render(width: number): string[] {
    try {
      return this.frame(width);
    } catch (error) {
      return [truncateToWidth(`the approval page could not draw: ${message(error)}`, width)];
    }
  }

  private frame(width: number): string[] {
    const inner = Math.max(16, width - 1);
    const lines: string[] = [];
    let focusAt = 0;
    let rowIndex = 0;
    for (const block of this.blocks()) {
      switch (block.kind) {
        case "title":
          lines.push(this.theme.bold(this.theme.fg("accent", block.text)));
          break;
        case "heading":
          lines.push("");
          lines.push(this.theme.bold(this.theme.fg("accent", block.text)));
          break;
        case "text":
          for (const line of this.wrap(block.text, inner)) lines.push(this.theme.fg("text", line));
          break;
        case "bullet":
          for (const [index, line] of this.wrap(block.text, inner - 4).entries())
            lines.push(this.theme.fg("muted", `${index === 0 ? "  - " : "    "}${line}`));
          break;
        case "row": {
          const at = rowIndex === this.focus;
          if (at) focusAt = lines.length;
          lines.push(this.rowLine(block, at, inner));
          if (this.editing && sameRow(this.editing.row, block.row))
            for (const line of this.editing.input.render(inner - 4)) lines.push(`    ${line}`);
          rowIndex += 1;
          break;
        }
      }
    }

    const height = Math.max(6, this.viewport.rows - RESERVED_ROWS);
    const extra = this.editing ? 2 : 0;
    if (this.scroll === "recenter") {
      this.offset = Math.max(0, focusAt - Math.floor(height / 3));
      this.scroll = "follow";
    } else if (this.scroll === "follow") {
      if (focusAt < this.offset) this.offset = focusAt;
      if (focusAt + 1 + extra > this.offset + height) this.offset = focusAt + 1 + extra - height;
    }
    this.offset = Math.max(0, Math.min(this.offset, Math.max(0, lines.length - height)));

    const shown = lines
      .slice(this.offset, this.offset + height)
      .map((line) => truncateToWidth(line, width));
    shown.push("");
    for (const hint of this.hint())
      for (const line of this.wrap(hint, width - 1))
        shown.push(this.theme.fg("dim", truncateToWidth(line, width)));
    if (this.warning)
      for (const line of this.wrap(this.warning, width - 1))
        shown.push(this.theme.fg("warning", truncateToWidth(line, width)));
    return shown;
  }

  /** The page's blocks, recomputed from the edits so every keystroke shows its effect. */
  private blocks(): ApprovalBlock[] {
    return approvalBlocks(this.source.flow, this.source.handoff, this.page, this.source.settings);
  }

  private rows(): ApprovalRow[] {
    return this.blocks().flatMap((block) => (block.kind === "row" ? [block.row] : []));
  }

  private focusedRow(): ApprovalRow | undefined {
    return this.rows()[this.focus];
  }

  private rowLine(
    block: Extract<ApprovalBlock, { kind: "row" }>,
    at: boolean,
    inner: number,
  ): string {
    const cursor = at ? this.theme.fg("accent", "▸ ") : "  ";
    const value = block.value === "" ? "" : `  ${block.value}`;
    const label = truncateToWidth(block.label, Math.max(12, inner - value.length - 3), "…");
    const text = at
      ? this.theme.bold(this.theme.fg("accent", label))
      : this.theme.fg("text", label);
    return `${cursor}${text}${this.theme.fg("muted", value)}`;
  }

  private wrap(text: string, width: number): string[] {
    const room = Math.max(8, width);
    return text
      .split("\n")
      .flatMap((line) => (line.trim() === "" ? [""] : wrapTextWithAnsi(line, room)));
  }

  private hint(): string[] {
    if (this.editing) return ["enter keeps it · esc drops it"];
    return [
      "↑↓ move · ←→ change · enter edit or choose · esc cancel",
      "m mode · r run model · f final reviewer · t tier · q question · a approve · s send back",
    ];
  }

  private move(delta: number): void {
    const rows = this.rows();
    if (rows.length === 0) return;
    this.focus = (this.focus + delta + rows.length) % rows.length;
    this.scroll = "follow";
    this.warning = undefined;
    this.viewport.requestRender();
  }

  /** Left/right on a cycle row: the mode, a thinking level, or an item's tier. */
  private change(delta: number): void {
    const row = this.focusedRow();
    if (!row) return;
    this.warning = undefined;
    const cycle = <T>(values: readonly T[], current: T): T =>
      values[(values.indexOf(current) + delta + values.length) % values.length];
    switch (row.kind) {
      case "mode":
        this.page.mode = cycle<Mode>(MODES, this.page.mode);
        break;
      case "settingThinking": {
        const current = this.page.settings[row.key].thinking;
        const index = current === undefined ? (delta > 0 ? -1 : 0) : LEVELS.indexOf(current);
        this.page.settings[row.key].thinking =
          LEVELS[(index + delta + LEVELS.length) % LEVELS.length];
        break;
      }
      case "tier":
        this.page.tiers[row.id] = this.page.tiers[row.id] === "deep" ? "flash" : "deep";
        break;
      default:
        break;
    }
    this.viewport.requestRender();
  }

  private activate(): void {
    const row = this.focusedRow();
    if (!row) return;
    switch (row.kind) {
      case "approve": {
        // A refused value would silently fall back, so the page stays open and says which.
        const { reports } = applyPage(this.source.flow, this.opened, this.page);
        if (reports.length > 0) {
          this.warning = `fix before approving: ${reports.map(reportLine).join("; ")}`;
          this.viewport.requestRender();
          return;
        }
        this.finish({ kind: "approve" });
        return;
      }
      case "cancel":
        this.finish({ kind: "cancel" });
        return;
      case "back":
        this.edit(row, "", "what the plan must change");
        return;
      case "setting":
        this.edit(row, "", this.page.settings[row.key].target);
        return;
      case "settingDeep":
        this.edit(row, "", this.page.settings.items.deep ?? "");
        return;
      case "question":
        this.edit(row, this.page.answers[row.id] ?? "", "your answer");
        return;
      default:
        // The cycle rows advance on enter as they do on the right arrow.
        this.change(1);
    }
  }

  private edit(row: ApprovalRow, value: string, placeholder: string): void {
    const input = new Input({ placeholder });
    input.setValue(value);
    input.onSubmit = (text) => this.commit(row, text);
    input.onEscape = () => {
      this.editing = undefined;
      this.warning = undefined;
      this.viewport.requestRender();
    };
    this.editing = { row, input };
    this.scroll = "recenter";
    this.warning = undefined;
    this.viewport.requestRender();
  }

  /** Enter inside an edit: validate, or keep the field open and say why not. */
  private commit(row: ApprovalRow, text: string): void {
    const value = text.trim();
    switch (row.kind) {
      case "back":
        if (value === "") {
          this.warning = "a send-back needs a note saying what to change";
          this.viewport.requestRender();
          return;
        }
        this.finish({ kind: "back", note: value });
        return;
      // An empty field keeps the value it opened on: a blank target is no setting.
      case "setting":
        if (value === "") break;
        this.page.settings[row.key].target = value;
        break;
      case "settingDeep":
        if (value === "") break;
        this.page.settings[row.key].deep = value;
        break;
      case "question":
        if (value === "") delete this.page.answers[row.id];
        else this.page.answers[row.id] = value;
        break;
      default:
        break;
    }
    this.editing = undefined;
    this.warning = undefined;
    this.viewport.requestRender();
  }

  private finish(decision: PageDecision): void {
    if (this.closed) return;
    this.closed = true;
    this.done({ ...decision, page: this.page } as PageResult);
  }
}

/** The leaf's `flow` settings key; read inside a handler, never at load (pi throws there). */
const leafOf = (pi: ExtensionAPI): unknown => {
  try {
    return (pi.getSettings() as { flow?: unknown } | undefined)?.flow;
  } catch {
    return undefined;
  }
};

/**
 * The page on a host with no terminal (RPC, JSON, print): the same content on
 * disk, then the three actions as one `select` — and the note as an `input`.
 */
const askDialogs = async (ctx: ExtensionCommandContext, page: PageState): Promise<PageResult> => {
  const choice = await ctx.ui.select("Approve this plan?", ["approve", "send back", "cancel"]);
  if (choice === "approve") return { kind: "approve", page };
  if (choice === "send back") {
    const note =
      (await ctx.ui.input("What should the plan change?", "the note the planner gets")) ?? "";
    if (note.trim() === "") return { kind: "cancel", page };
    return { kind: "back", note: note.trim(), page };
  }
  return { kind: "cancel", page };
};

/**
 * C5: show the plan, let the owner change the mode, the step settings, item
 * tiers and open-question answers, and answer approve, back or cancel. The
 * edits are written before the answer is returned: one `Tier:` line per
 * retiered item and one dated Amendments entry per answer whatever the answer,
 * and, only on approval, `FLOW.json`'s mode and the settings fields the owner
 * changed. A write that fails, or an edited setting `resolveSettings` refuses,
 * refuses the approval instead of starting a run on something other than what
 * the owner saw.
 */
export const approve = async (
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
  flow: Flow,
  handoff: ParsedHandoff,
  verdict: JudgeHandoffVerdict,
  read: typeof readText = readText,
): Promise<Approval> => {
  const settings = settingsOf(leafOf(pi), flow).settings;
  const page = initialPage(flow, handoff, verdict, settings);
  // The overlay edits `page` in place; this is what it opened on.
  const opened = structuredClone(page);
  const handoffPath = join(flow.planDir, "HANDOFF.md");
  const handoffText = read(handoffPath);
  // The conductor parsed this file a moment ago; if it is gone now, approving
  // would start a run on a plan nobody can read.
  if (handoffText === undefined) {
    ctx.ui.notify(`flow: HANDOFF.md is no longer in ${flow.planDir}.`, "error");
    return { kind: "cancel" };
  }

  // D13's other half: the same content as the overlay shows, on disk.
  try {
    writeFileSync(
      join(flow.planDir, "APPROVAL.md"),
      approvalMarkdown(approvalBlocks(flow, handoff, page, settings)),
    );
  } catch (error) {
    ctx.ui.notify(`flow: could not write APPROVAL.md: ${message(error)}`, "warning");
  }

  let result: PageResult;
  if (ctx.mode === "tui") {
    const answered = await ctx.ui.custom<PageResult>(
      (tui, theme, _keybindings, done) =>
        new ApprovalOverlay(
          { rows: tui.terminal.rows, requestRender: () => tui.requestRender() },
          theme,
          { flow, handoff, settings },
          page,
          done,
        ),
      // The page is a document: it takes nearly the whole width, and its own
      // scroll budget leaves the composer below it alone.
      { overlay: true, overlayOptions: { width: "92%", minWidth: 40, maxHeight: "100%" } },
    );
    // `custom` answers undefined on a host that cannot draw components.
    result = answered ?? { kind: "cancel", page };
  } else {
    result = await askDialogs(ctx, page);
  }

  // The owner's word lands in the plan before the answer is acted on. Re-read
  // it: writing the opening snapshot would erase a planner's concurrent edit.
  let currentText: string | undefined;
  try {
    currentText = read(handoffPath);
  } catch (error) {
    ctx.ui.notify(`flow: could not re-read HANDOFF.md: ${message(error)}`, "error");
    return { kind: "cancel" };
  }
  if (currentText !== handoffText) {
    ctx.ui.notify(
      "flow: HANDOFF.md changed under the approval page; the page's edits were not applied.",
      "error",
    );
    return { kind: "cancel" };
  }
  try {
    const edited = rewriteTiers(currentText, tierEdits(handoff, result.page));
    const amended = appendAmendments(edited, amendmentEntries(handoff, result.page, today()));
    if (amended !== handoffText) writeFileSync(handoffPath, amended);
  } catch (error) {
    ctx.ui.notify(`flow: could not rewrite HANDOFF.md: ${message(error)}`, "error");
    return { kind: "cancel" };
  }
  try {
    // Rewritten with the edits, so the plan directory records what was decided.
    writeFileSync(
      join(flow.planDir, "APPROVAL.md"),
      approvalMarkdown(approvalBlocks(flow, handoff, result.page, settings)),
    );
  } catch (error) {
    ctx.ui.notify(`flow: could not write APPROVAL.md: ${message(error)}`, "warning");
  }
  // Settings and mode land only on approval: after a send-back or a cancel the
  // next page opens on the next judge's suggestions, not on this page's.
  if (result.kind === "back") return { kind: "back", note: result.note };
  if (result.kind === "cancel") return { kind: "cancel" };

  const applied = applyPage(flow, opened, result.page);
  if (applied.reports.length > 0) {
    ctx.ui.notify(
      `flow: the page's settings were refused, so nothing was approved:\n${applied.reports.map(reportLine).join("\n")}`,
      "error",
    );
    return { kind: "cancel" };
  }
  try {
    writeFlow(applied.flow);
  } catch (error) {
    ctx.ui.notify(`flow: could not write FLOW.json: ${message(error)}`, "error");
    return { kind: "cancel" };
  }
  return { kind: "approve", flow: applied.flow };
};
