/**
 * The `/memory` panel: the rows, the selected entry's detail and the actions,
 * in one component, so the screen never closes for something answerable in
 * place. Only `edit` (needs pi's editor) and `review` (starts an agent turn)
 * finish it; the caller runs those and reopens on the same row.
 *
 * Scanning is the job, so the list is the top pane and it is never hidden: the
 * detail fits itself to the selected entry up to a share of the panel and cuts
 * with a marker rather than growing a scrollbar.
 */
import type { Theme } from "@earendil-works/pi-coding-agent";
import {
  Key,
  matchesKey,
  visibleWidth,
  type Component,
  type TUI,
  type TuiMouseEvent,
  type TuiMouseEventResult,
} from "@earendil-works/pi-tui";
import { frame, frameWidth } from "../../../shared/panel.ts";
import type { HotIndex } from "../hot.ts";
import type { Entry, Scope } from "../store.ts";
import {
  buildModel,
  detailLines,
  emptyLines,
  groupLine,
  rowLine,
  summary,
  type Model,
  type Row,
} from "./rows.ts";

export type BrowserEffect = { type: "edit"; entry: Entry } | { type: "review" };

export type BrowserDeps = {
  scope: Scope;
  /** Re-reads the stores and the hot index after a write. */
  reload(): HotIndex;
  forget(entry: Entry): Promise<void>;
  promote(entry: Entry, target: "main" | "global"): Promise<void>;
  priority(entry: Entry, delta: number): Promise<void>;
};

type Target = { id: "main" | "global"; label: string };

type Mode =
  | { kind: "list" }
  | { kind: "search"; draft: string }
  | { kind: "confirm"; entry: Entry }
  | { kind: "promote"; entry: Entry; targets: Target[]; choice: number };

// Rows kept free around the overlay, as the cost panel does.
const MARGIN_ROWS = 4;
const PANEL_BG = "userMessageBg";
const LIST_FLOOR = 4;
const DETAIL_SHARE = 0.6;
const PROMPT_STATEMENT = 48;

export class MemoryBrowser implements Component {
  private readonly tui: TUI;
  private readonly theme: Theme;
  private readonly deps: BrowserDeps;
  private readonly done: (effect: BrowserEffect | undefined) => void;
  private readonly initial: string | undefined;
  private model: Model;
  private hot: HotIndex;
  private mode: Mode = { kind: "list" };
  private cursor = 0;
  private scroll = 0;
  /** Screen lines of the list, for turning a click's row into an entry. */
  private visible: { text: string; row?: Row }[] = [];
  /** One line under the list after a refused action; cleared by the next key. */
  private notice: string | undefined;
  private busy = false;

  constructor(
    tui: TUI,
    theme: Theme,
    deps: BrowserDeps,
    done: (effect: BrowserEffect | undefined) => void,
    initial: string | undefined,
  ) {
    this.tui = tui;
    this.theme = theme;
    this.deps = deps;
    this.done = done;
    this.initial = initial;
    this.hot = deps.reload();
    this.model = buildModel(deps.scope, this.hot);
    this.selectInitial();
  }

  invalidate() {}

  render(width: number): string[] {
    const theme = this.theme;
    const inner = frameWidth(width);
    const room = Math.max(6, this.tui.terminal.rows - MARGIN_ROWS - 2);

    if (this.model.rows.length === 0) {
      return frame(theme, width, {
        title: this.title(),
        note: this.note(width),
        hints: this.hints(width),
        lines: this.model.filter
          ? [`Nothing matches “${this.model.filter}”.`]
          : emptyLines(this.deps.scope),
        background: PANEL_BG,
      });
    }

    const selected = this.selected();
    const detail = selected ? detailLines(theme, inner, selected, this.model) : [];
    const share = Math.max(3, Math.floor(room * DETAIL_SHARE));
    let shown =
      detail.length > share
        ? [
            ...detail.slice(0, share - 1),
            theme.fg("dim", `… ${detail.length - share + 1} more lines · e to edit`),
          ]
        : detail;
    let listRoom = room - shown.length - 1;
    if (listRoom < LIST_FLOOR) {
      shown = shown.slice(0, Math.max(0, room - LIST_FLOOR - 1));
      listRoom = room - shown.length - 1;
    }

    this.visible = this.model.groups.flatMap((group) => [
      { text: groupLine(theme, inner, group) },
      ...group.rows.map((row) => ({ text: rowLine(theme, inner, row, row === selected), row })),
    ]);
    const cursorLine = Math.max(
      0,
      this.visible.findIndex((slot) => slot.row === selected),
    );
    this.scroll = Math.min(Math.max(0, this.scroll), Math.max(0, this.visible.length - listRoom));
    if (cursorLine < this.scroll) this.scroll = cursorLine;
    if (cursorLine >= this.scroll + listRoom) this.scroll = cursorLine - listRoom + 1;

    const list = this.visible.slice(this.scroll, this.scroll + listRoom).map((slot) => slot.text);
    return frame(theme, width, {
      title: this.title(),
      note: this.note(width),
      hints: this.hints(width),
      lines: [...list, ...shown],
      split: list.length,
      background: PANEL_BG,
    });
  }

  handleInput(data: string): void {
    this.notice = undefined;
    if (this.mode.kind === "search") return this.searchKey(data);
    if (this.mode.kind === "confirm") return this.confirmKey(data);
    if (this.mode.kind === "promote") return this.promoteKey(data);

    if (matchesKey(data, Key.escape) || data === "q") return this.done(undefined);
    if (matchesKey(data, Key.up) || data === "k") return this.move(-1);
    if (matchesKey(data, Key.down) || data === "j") return this.move(1);
    if (matchesKey(data, Key.pageUp)) return this.move(-this.page());
    if (matchesKey(data, Key.pageDown)) return this.move(this.page());
    if (matchesKey(data, Key.home)) return this.moveTo(0);
    if (matchesKey(data, Key.end)) return this.moveTo(this.model.rows.length - 1);
    if (data === "/") {
      this.mode = { kind: "search", draft: this.model.filter };
      return this.repaint();
    }
    if (data === "r") return this.done({ type: "review" });
    return this.action(data);
  }

  handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    if (event.type === "wheel" && event.wheelDelta) {
      this.move(event.wheelDelta > 0 ? 1 : -1);
      return { handled: true };
    }
    if (event.type !== "click" || event.button !== "left") return undefined;
    // Body line 0 is the top border, so the list starts at y = 1 and ends before the divider.
    const slot = this.visible[event.y - 1];
    const index = slot?.row ? this.model.rows.indexOf(slot.row) : undefined;
    if (index === undefined) return undefined;
    this.moveTo(index);
    return { handled: true, focus: true };
  }

  private title(): string {
    const label = this.deps.scope.project?.label ?? "no repo";
    return ` ✦ Memory · ${label} `;
  }

  /** The counts, or just the tally that fits a narrow panel. */
  private note(width: number): string | undefined {
    if (width < 56) return undefined;
    return width < 80 ? `${this.model.counts.hot} hot` : summary(this.model.counts);
  }

  private hints(width: number): string {
    if (this.notice) return this.theme.fg("warning", ` ${this.notice} `);
    const mode = this.mode;
    if (mode.kind === "search")
      return this.theme.fg(
        "text",
        ` / ${mode.draft}█  ${this.model.rows.length} of ${this.total()} shown · enter keeps · esc clears `,
      );
    if (mode.kind === "confirm")
      return this.theme.fg(
        "warning",
        ` Forget “${mode.entry.statement.slice(0, PROMPT_STATEMENT)}${mode.entry.statement.length > PROMPT_STATEMENT ? "…" : ""}”?  y / n `,
      );
    if (mode.kind === "promote") {
      const targets = mode.targets
        .map((target, index) =>
          index === mode.choice
            ? this.theme.bold(this.theme.fg("accent", target.label))
            : this.theme.fg("dim", target.label),
        )
        .join(this.theme.fg("dim", " / "));
      const keys =
        mode.targets.length > 1
          ? "←→ picks · enter promotes · esc cancels "
          : "enter promotes · esc cancels ";
      return ` Promote to ${targets} ${this.theme.fg("dim", `· ${keys}`)}`;
    }
    const row = this.selected();
    const writable = row !== undefined && row.entry.store.writable;
    const key = (name: string, label: string, enabled = true) =>
      enabled
        ? this.theme.fg("text", `${name} ${label}`)
        : this.theme.fg("dim", `${name} ${label}`);
    // Keys give way from the least used end so a narrow panel keeps a whole hint
    // rather than half of one; closing is always last and never dropped.
    const close = key("esc", "close");
    const room = width - 4 - visibleWidth(close) - 2;
    const parts: string[] = [];
    let used = 0;
    for (const part of [
      key("e", "edit", writable),
      key("p", "promote", row !== undefined),
      key("d", "forget", writable),
      key("+/-", "priority", writable),
      key("r", "review"),
      key("/", "search"),
    ]) {
      const cost = visibleWidth(part) + 2;
      if (used + cost > room) break;
      parts.push(part);
      used += cost;
    }
    return ` ${[...parts, close].join("  ")} `;
  }

  /** Runs the list mode's single-key actions, refusing the ones the entry cannot take. */
  private action(data: string): void {
    const row = this.selected();
    if (!row) return;
    if (
      data === "e" ||
      data === "d" ||
      data === "+" ||
      data === "=" ||
      data === "-" ||
      data === "_"
    ) {
      if (!row.entry.store.writable) {
        this.notice = `${row.entry.store.origin} memory is read-only from here · p promotes it`;
        return this.repaint();
      }
      if (data === "e") return this.done({ type: "edit", entry: row.entry });
      if (data === "d") {
        this.mode = { kind: "confirm", entry: row.entry };
        return this.repaint();
      }
      const delta = data === "+" || data === "=" ? 10 : -10;
      void this.mutate(() => this.deps.priority(row.entry, delta));
      return;
    }
    if (data !== "p") return;
    const targets = this.targets(row.entry);
    if (targets.length === 0) {
      this.notice = "already in every store this session can write";
      return this.repaint();
    }
    this.mode = { kind: "promote", entry: row.entry, targets, choice: 0 };
    return this.repaint();
  }

  private searchKey(data: string): void {
    const mode = this.mode as Extract<Mode, { kind: "search" }>;
    if (matchesKey(data, Key.escape)) {
      this.mode = { kind: "list" };
      this.setFilter("");
      return;
    }
    if (matchesKey(data, Key.enter)) {
      this.mode = { kind: "list" };
      return this.repaint();
    }
    if (matchesKey(data, Key.backspace)) return this.setFilter(mode.draft.slice(0, -1));
    if (data.length === 1 && data >= " ") {
      this.mode = { kind: "search", draft: mode.draft + data };
      return this.setFilter(mode.draft + data);
    }
  }

  private confirmKey(data: string): void {
    const mode = this.mode as Extract<Mode, { kind: "confirm" }>;
    if (data === "y" || data === "Y") {
      void this.mutate(() => this.deps.forget(mode.entry));
      return;
    }
    if (data === "n" || data === "N" || matchesKey(data, Key.escape)) {
      this.mode = { kind: "list" };
      return this.repaint();
    }
  }

  private promoteKey(data: string): void {
    const mode = this.mode as Extract<Mode, { kind: "promote" }>;
    const step =
      matchesKey(data, Key.left) || data === "h"
        ? -1
        : matchesKey(data, Key.right) || data === "l"
          ? 1
          : 0;
    if (step !== 0) {
      mode.choice = (mode.choice + step + mode.targets.length) % mode.targets.length;
      return this.repaint();
    }
    if (matchesKey(data, Key.escape)) {
      this.mode = { kind: "list" };
      return this.repaint();
    }
    if (!matchesKey(data, Key.enter)) return;
    const target = mode.targets[mode.choice];
    void this.mutate(() => this.deps.promote(mode.entry, target.id));
  }

  /** Applies a write, then re-reads the stores so the row moves where it now belongs. */
  private async mutate(write: () => Promise<void>): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    const keep = this.selected()?.entry.id;
    try {
      await write();
    } catch (error) {
      this.notice = String(error);
    } finally {
      this.busy = false;
      this.mode = { kind: "list" };
      this.reload(keep);
    }
  }

  private reload(keep?: string): void {
    this.hot = this.deps.reload();
    this.model = buildModel(this.deps.scope, this.hot, this.model.filter);
    const index = keep ? this.model.rows.findIndex((row) => row.entry.id === keep) : -1;
    this.cursor =
      index >= 0 ? index : Math.min(this.cursor, Math.max(0, this.model.rows.length - 1));
    this.repaint();
  }

  private setFilter(filter: string): void {
    this.model = buildModel(this.deps.scope, this.hot, filter);
    this.cursor = Math.min(this.cursor, Math.max(0, this.model.rows.length - 1));
    this.repaint();
  }

  private selectInitial(): void {
    if (!this.initial) return;
    const index = this.model.rows.findIndex((row) => row.entry.id === this.initial);
    if (index >= 0) this.cursor = index;
  }

  private selected(): Row | undefined {
    return this.model.rows[this.cursor];
  }

  private total(): number {
    return Object.values(this.model.counts).reduce((sum, count) => sum + count, 0);
  }

  private targets(entry: Entry): Target[] {
    const scope = this.deps.scope;
    const main = scope.visible.find((store) => store.origin === "main");
    const targets: Target[] = [];
    if (main && entry.store.dir !== main.dir) targets.push({ id: "main", label: main.label });
    if (entry.store.dir !== scope.global.dir) targets.push({ id: "global", label: "global" });
    return targets;
  }

  private page(): number {
    return Math.max(1, Math.floor(this.tui.terminal.rows / 2));
  }

  private move(delta: number): void {
    this.moveTo(this.cursor + delta);
  }

  private moveTo(index: number): void {
    this.cursor = Math.max(0, Math.min(index, Math.max(0, this.model.rows.length - 1)));
    this.repaint();
  }

  private repaint(): void {
    this.tui.requestRender();
  }
}
