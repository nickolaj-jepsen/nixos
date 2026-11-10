/**
 * `/hub` (alt+h): every session the hub has, in its own order and with the
 * bar's words — what wants you, what finished, what is working, then the idle
 * ones on slim lines and the last few that ended behind a fold.
 *
 * It draws the rows the hub pushes over this session's own connection, so
 * opening it costs no process and it follows a dismissal as it lands. Enter goes
 * to a live session (its window here, or its tmux pane on the host it is on) or
 * resumes one that ended; `x` puts a finished turn away and `o` opens the
 * session's notes in the bar's reader, listing them here when no bar took them.
 * j/k move, q and Esc close.
 */
import { execFile } from "node:child_process";
import path from "node:path";
import type {
  ExtensionAPI,
  ExtensionContext,
  Theme,
  ThemeColor,
} from "@earendil-works/pi-coding-agent";
import {
  type Component,
  Key,
  matchesKey,
  truncateToWidth,
  type TUI,
  visibleWidth,
} from "@earendil-works/pi-tui";
import { formatAge } from "./lib/format.ts";
import type { Hub } from "./lib/hub.ts";
import type { HubRow, HubState } from "./lib/protocol.gen.ts";
import { frame, frameWidth } from "../shared/panel.ts";
import type { Services } from "./services.ts";

const SHORTCUT = "alt+h";
// As many as the bar keeps behind its fold.
const MAX_ENDED = 5;
// Rows kept free around the overlay, so the editor border stays in view.
const MARGIN_ROWS = 4;
const PANEL_BG = "userMessageBg";
const FOLD_ID = "fold:ended";

/** A session the hub still has, or the one that ended, or the fold that hides them. */
type Item = {
  id: string;
  name: string;
  repo: string;
  host?: string;
  state: HubState | "ended" | "fold";
  since: number;
  turn?: number;
  /** Why it wants you, what it is doing, or what it did. */
  reason: string;
  /** Whether the hub can go to it: its window here, or a pane over there. */
  reachable: boolean;
  /** What resumes an ended session, as the hub would run it. */
  resume?: string;
  /** How many it hides, for the fold. */
  members?: number;
};

type Ended = ReturnType<Hub["recent"]>[number];

const STATE_WORD: Record<HubState | "ended", string> = {
  asking: "waiting",
  "needs-reply": "waiting",
  failed: "failed",
  done: "finished",
  working: "working",
  idle: "idle",
  ended: "ended",
};

const STATE_TONE: Record<HubState | "ended", ThemeColor> = {
  asking: "warning",
  "needs-reply": "warning",
  failed: "error",
  done: "success",
  working: "muted",
  idle: "dim",
  ended: "dim",
};

/** The heading a row goes under, in the popout's words. */
const sectionOf = (state: HubState): string => {
  if (state === "asking" || state === "needs-reply") return "Waiting on you";
  if (state === "failed" || state === "done") return "Finished";
  return state === "working" ? "Working" : "Idle";
};

const folderName = (cwd: string) => path.basename(cwd) || cwd;
const displayName = (name: string, cwd: string, agent: string) => name || folderName(cwd) || agent;

/** What a row is about, in the one line the detail has for it. */
const reasonOf = (row: HubRow) =>
  row.ask || row.waitingFor || row.summary || row.reason || row.doing || row.label || "";

const live = (row: HubRow): Item => ({
  id: row.id,
  name: displayName(row.name, row.cwd, row.agent),
  repo: row.project || folderName(row.cwd),
  host: row.host,
  state: row.state,
  since: row.since,
  turn: row.turn,
  reason: reasonOf(row),
  // As the hub's own `focus` goes: a window here, else a pane or a page over there.
  reachable: row.window !== null || Boolean(row.host && (row.tmux || row.bridge)),
});

const ended = (row: Ended): Item => ({
  id: row.id,
  name: displayName(row.label, row.cwd, row.agent),
  repo: row.project || folderName(row.cwd),
  host: row.host,
  state: "ended",
  since: row.endedAt,
  reason: row.summary,
  reachable: true,
  resume: row.resume,
});

/** What the overlay may do to a row; false when the hub could not be asked at all. */
type Ops = {
  focus: (id: string) => boolean;
  resume: (id: string) => boolean;
  dismiss: (id: string, turn?: number) => boolean;
  /** Puts the session's notes up in the bar's reader; false when none took them. */
  notes: (id: string) => Promise<boolean>;
};

export class SessionsOverlay implements Component {
  private selectedId = "";
  private endedOpen = false;
  private scroll = 0;
  private notice = "";
  private readonly tui: TUI;
  private readonly theme: Theme;
  private readonly hub: Hub;
  private readonly ops: Ops;
  private readonly done: () => void;

  constructor(tui: TUI, theme: Theme, hub: Hub, ops: Ops, done: () => void) {
    this.tui = tui;
    this.theme = theme;
    this.hub = hub;
    this.ops = ops;
    this.done = done;
  }

  /** A push moved the rows under the open overlay; draw them where they are now. */
  refresh() {
    this.tui.requestRender();
  }

  invalidate() {}

  /** The hub's own order, with the idle ones last as the bar draws them. */
  private items(): Item[] {
    const rows = this.hub.rows();
    const liveRows = rows
      .filter((row) => row.state !== "idle")
      .concat(rows.filter((r) => r.state === "idle"));
    const items = liveRows.map(live);
    const gone = this.hub.recent().slice(0, MAX_ENDED).map(ended);
    if (gone.length > 0)
      items.push({
        id: FOLD_ID,
        name: `Ended · ${gone.length}`,
        repo: "",
        state: "fold",
        since: 0,
        reason: "",
        reachable: false,
        members: gone.length,
      });
    if (this.endedOpen) items.push(...gone);
    return items;
  }

  /** Where the selection is, following its row as rows come and go around it. */
  private index(items: Item[]): number {
    const at = items.findIndex((item) => item.id === this.selectedId);
    if (at >= 0) return at;
    return Math.max(
      0,
      items.findIndex((item) => item.state !== "fold"),
    );
  }

  private select(items: Item[], index: number) {
    this.selectedId = items[index]?.id ?? "";
  }

  private move(items: Item[], step: number) {
    if (items.length === 0) return;
    const next = Math.max(0, Math.min(items.length - 1, this.index(items) + step));
    this.select(items, next);
    this.notice = "";
    this.tui.requestRender();
  }

  private act(items: Item[]) {
    const item = items[this.index(items)];
    if (!item) return;
    this.notice = "";
    if (item.state === "fold") {
      this.endedOpen = !this.endedOpen;
      this.tui.requestRender();
      return;
    }
    if (item.state === "ended") {
      if (!this.ops.resume(item.id))
        this.notice = "agent-hub isn't running: nothing to resume with";
      else this.done();
      this.tui.requestRender();
      return;
    }
    if (!item.reachable) {
      this.notice = `${item.name} is not on this desktop: there is nothing here to go to`;
      this.tui.requestRender();
      return;
    }
    if (!this.ops.focus(item.id)) this.notice = "agent-hub isn't running: nothing to go to";
    else this.done();
    this.tui.requestRender();
  }

  private dismiss(items: Item[]) {
    const item = items[this.index(items)];
    if (!item) return;
    this.notice = "";
    if (
      item.state === "ended" ||
      item.state === "fold" ||
      item.state === "working" ||
      item.state === "idle"
    ) {
      this.notice = `${item.name} has no finished turn to put away`;
    } else if (!this.ops.dismiss(item.id, item.turn)) {
      this.notice = "agent-hub isn't running: nothing to put away";
    }
    this.tui.requestRender();
  }

  private openNotes(items: Item[]) {
    const item = items[this.index(items)];
    if (!item || item.state === "fold") return;
    this.notice = "";
    void this.ops.notes(item.id).then((taken) => {
      if (taken) this.done();
      this.tui.requestRender();
    });
  }

  handleInput(data: string) {
    const items = this.items();
    this.notice = "";
    if (matchesKey(data, Key.escape) || data === "q") {
      this.done();
      return;
    }
    if (matchesKey(data, Key.down) || data === "j") return this.move(items, 1);
    if (matchesKey(data, Key.up) || data === "k") return this.move(items, -1);
    if (matchesKey(data, Key.enter)) return this.act(items);
    if (data === "x") return this.dismiss(items);
    if (data === "o") return this.openNotes(items);
    this.tui.requestRender();
  }

  /** The columns of one row: its marker, the name, the repo behind it, and how it stands. */
  private columns(item: Item, selected: boolean) {
    const state =
      item.state === "fold"
        ? ""
        : `${STATE_WORD[item.state]} · ${formatAge(Date.now() - item.since, "now")}`;
    // Idle rows are slim, as at the bar: their name and state are the whole line.
    const repo =
      item.repo && item.repo !== item.name && item.state !== "idle" ? `  ${item.repo}` : "";
    return {
      mark: selected ? "❯ " : "  ",
      name: item.name + (item.host ? ` · ${item.host}` : ""),
      repo,
      state,
    };
  }

  render(width: number): string[] {
    const theme = this.theme;
    const items = this.items();
    const index = this.index(items);
    this.select(items, index);
    const inner = frameWidth(width);
    const room = Math.max(4, this.tui.terminal.rows - MARGIN_ROWS - 2);

    const body: string[] = [];
    let focus = 0;
    let section = "";
    for (const [at, item] of items.entries()) {
      if (item.state !== "fold" && item.state !== "ended") {
        const next = sectionOf(item.state);
        if (next !== section) {
          if (body.length > 0) body.push("");
          body.push(theme.fg("accent", theme.bold(next)));
          section = next;
        }
      }
      if (at === index) focus = body.length;
      body.push(this.line(item, at === index, inner));
    }
    if (items.length === 0)
      body.push(theme.fg("dim", this.hub.connected() ? "no sessions" : "the hub is gone"));

    const detail = this.detail(items[index]);
    const notice = this.notice ? [theme.fg("warning", this.notice)] : [];
    // The selection's detail and any notice are the floor of the panel, so a
    // long list scrolls under them instead of pushing them out of view.
    const listRoom = Math.max(3, room - detail.length - notice.length - 1);
    if (this.scroll > focus) this.scroll = focus;
    if (this.scroll + listRoom <= focus) this.scroll = focus - listRoom + 1;
    this.scroll = Math.max(0, Math.min(this.scroll, Math.max(0, body.length - listRoom)));
    const shown = body.slice(this.scroll, this.scroll + listRoom);

    const hints = theme.fg("dim", " j/k move · enter go · x dismiss · o notes · q close ");
    return frame(theme, width, {
      title: " Sessions ",
      hints,
      lines: [...shown, "", ...detail, ...notice],
      split: shown.length,
      background: PANEL_BG,
    });
  }

  /** The whole row painted, or dim facts beside a plain name: one line, never two. */
  private line(item: Item, selected: boolean, width: number): string {
    const theme = this.theme;
    const { mark, name, repo, state } = this.columns(item, selected);
    const room = width - visibleWidth(mark) - visibleWidth(state) - 1;
    const label = truncateToWidth(name, room, "…", true);
    const rest = Math.max(0, room - visibleWidth(label));
    const shownRepo = repo ? truncateToWidth(repo, rest, "…", true) : "";
    const fill = " ".repeat(Math.max(1, room - visibleWidth(label) - visibleWidth(shownRepo)));
    const plain = mark + label + shownRepo + fill + state;
    if (selected) return theme.bg("selectedBg", theme.fg("text", plain));
    const tone = item.state === "fold" ? "accent" : STATE_TONE[item.state];
    return (
      theme.fg("accent", mark) +
      theme.fg("text", label) +
      theme.fg("dim", shownRepo) +
      fill +
      theme.fg(tone, state)
    );
  }

  /** What the selection is, in full: who, where, how it stands, and what it wants. */
  private detail(item: Item | undefined): string[] {
    const theme = this.theme;
    if (!item) return [];
    if (item.state === "fold") {
      return [
        theme.fg("text", `${item.name} · the last ${item.members} that ended`),
        theme.fg(
          "dim",
          `enter ${this.endedOpen ? "folds them away" : "lists them"}, so they can be resumed`,
        ),
      ];
    }
    const facts = [
      item.repo,
      item.host,
      `${STATE_WORD[item.state]} ${formatAge(Date.now() - item.since, "now")}`,
    ]
      .filter(Boolean)
      .join(" · ");
    const lines = [theme.fg("text", item.name) + theme.fg("dim", `  ${facts}`)];
    if (item.reason)
      lines.push(
        theme.fg(
          "dim",
          truncateToWidth(item.reason, frameWidth(this.tui.terminal.columns), "…", true),
        ),
      );
    if (item.resume) lines.push(theme.fg("dim", `resume: ${item.resume}`));
    return lines;
  }
}

const DESCRIPTION = "Every session the hub has: go to one, put a finished one away, read its notes";

/** The notes of another session, as the CLI lists them, for a bar that did not take them. */
function listNotes(session: string): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      "agent-hub",
      ["notes", "--session-id", session],
      { encoding: "utf8", timeout: 15_000 },
      (error, stdout) => (error ? reject(error) : resolve(stdout)),
    );
  });
}

export default function (pi: ExtensionAPI, services: Services) {
  const hub: Hub = services.hub;

  const open = async (ctx: ExtensionContext) => {
    if (ctx.mode !== "tui" || !ctx.hasUI) return;
    // Rows of a hub that is gone are worth nothing, and the next attach pushes them again.
    if (!hub.connected()) {
      ctx.ui.notify("sessions: agent-hub isn't running", "warning");
      return;
    }
    const ops: Ops = {
      focus: (id) => hub.focus(id),
      resume: (id) => hub.resume(id),
      dismiss: (id, turn) => hub.dismiss(id, turn),
      notes: async (id) => {
        if (await hub.show(id)) return true;
        // No bar took the reader, or this session is hidden from it: the list stands in.
        try {
          const list = (await listNotes(id)).trim().split("\n").filter(Boolean);
          ctx.ui.notify(
            list.length > 0 ? `notes:\n${list.slice(0, 10).join("\n")}` : "sessions: no notes yet",
            "info",
          );
        } catch {
          ctx.ui.notify(
            "sessions: no bar took the reader, and agent-hub could not list them",
            "warning",
          );
        }
        return false;
      },
    };
    let overlay: SessionsOverlay | undefined;
    // A push while it is open moves the rows under the selection.
    const off = hub.onRows(() => overlay?.refresh());
    try {
      await ctx.ui.custom<void>(
        (tui, theme, _keybindings, done) => {
          overlay = new SessionsOverlay(tui, theme, hub, ops, () => done());
          return overlay;
        },
        { overlay: true, overlayOptions: { anchor: "center", width: 76, margin: 1 } },
      );
    } finally {
      off();
      overlay = undefined;
    }
  };

  pi.registerCommand("hub", { description: DESCRIPTION, handler: (_args, ctx) => open(ctx) });
  pi.registerShortcut(SHORTCUT, { description: DESCRIPTION, handler: open });
}
