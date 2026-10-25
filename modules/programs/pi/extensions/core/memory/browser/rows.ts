/**
 * The browser's model and its text: which group an entry falls in, the line it
 * gets in the list, and the lines it gets in the detail pane. Pure, so the
 * `/memory list` output outside the TUI says the same words the panel draws.
 *
 * Grouping is by what a human has to decide, not by where the file lives: an
 * entry the next session will be given, one that only sits on disk, one whose
 * citation stopped resolving, and one whose worktree is gone. The store is a
 * tag on the row, because it is what promote writes to.
 */
import type { Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import { homedir } from "node:os";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import type { HotIndex } from "../hot.ts";
import { loadStoreCached, type Entry, type Scope } from "../store.ts";
import { STATUS_MARK, verifyRecent, type Verification } from "../verify.ts";

export type GroupId = "hot" | "cold" | "stale" | "orphan";

export const GROUP_ORDER: readonly GroupId[] = ["hot", "cold", "stale", "orphan"];

const GROUP_TITLE: Record<GroupId, string> = {
  hot: "hot · what the next session sees",
  cold: "cold · on disk only",
  stale: "stale · citations no longer resolve",
  orphan: "orphan · worktree gone",
};

export type Row = {
  entry: Entry;
  checks: Verification;
  group: GroupId;
  /** 1-based place in the hot index, for the hot group only. */
  rank?: number;
  /** Why the row needs attention: a stale citation or a removed worktree. */
  note?: string;
};

export type Group = { id: GroupId; title: string; rows: Row[] };

export type Model = {
  /** Non-empty groups only, in `GROUP_ORDER`. */
  groups: Group[];
  /** Every visible row, in the same order, for the cursor to index. */
  rows: Row[];
  /** Totals per group before the filter, so the header cannot lie while it narrows. */
  counts: Record<GroupId, number>;
  used: number;
  budget: number;
  filter: string;
};

export const MARK_COLOR: Record<Verification["status"], ThemeColor> = {
  verified: "success",
  stale: "warning",
  unverified: "dim",
};

const PRIORITY_COLOR = (priority: number): ThemeColor =>
  priority >= 80 ? "accent" : priority >= 40 ? "text" : "dim";

const KIND_WIDTH = 11;
/** Columns a row spends before its statement: cursor, mark, priority, kind, gaps. */
export const ROW_HEAD = 22;
const LABEL_WIDTH = 10;

const tag = (entry: Entry) =>
  entry.store.origin === "orphan" ? `orphan:${entry.store.label}` : entry.store.origin;

const home = homedir();
const tilde = (dir: string) => (dir.startsWith(`${home}/`) ? `~${dir.slice(home.length)}` : dir);

const matches = (row: Row, needle: string) =>
  needle.length === 0 ||
  `${row.entry.statement} ${row.entry.id} ${row.entry.kind} ${row.entry.store.label}`
    .toLowerCase()
    .includes(needle);

/** Reads the stores and the frozen hot index into the rows the browser shows. */
export function buildModel(scope: Scope, hot: HotIndex, filter = ""): Model {
  const ranks = new Map(hot.picks.map((pick, index) => [pick.entry.file, index + 1]));
  const rows: Row[] = [];
  for (const store of [...scope.visible, ...scope.orphans]) {
    for (const entry of loadStoreCached(store)) {
      const checks = verifyRecent(entry);
      const rank = ranks.get(entry.file);
      const group: GroupId =
        store.origin === "orphan"
          ? "orphan"
          : checks.status === "stale"
            ? "stale"
            : rank
              ? "hot"
              : "cold";
      const note =
        group === "stale"
          ? checks.checks.find((check) => check.status === "stale")?.note
          : group === "orphan"
            ? `worktree ${store.label} is gone`
            : undefined;
      rows.push({ entry, checks, group, rank, note });
    }
  }

  const counts: Record<GroupId, number> = { hot: 0, cold: 0, stale: 0, orphan: 0 };
  for (const row of rows) counts[row.group]++;

  // The hot group keeps the section's own order; the rest read by priority.
  const order = (a: Row, b: Row) =>
    a.group === "hot" && b.group === "hot"
      ? (a.rank ?? 0) - (b.rank ?? 0)
      : b.entry.priority - a.entry.priority || a.entry.id.localeCompare(b.entry.id);

  const needle = filter.trim().toLowerCase();
  const groups = GROUP_ORDER.map((id) => ({
    id,
    title: GROUP_TITLE[id],
    rows: rows.filter((row) => row.group === id && matches(row, needle)).sort(order),
  })).filter((group) => group.rows.length > 0);

  return {
    groups,
    rows: groups.flatMap((group) => group.rows),
    counts,
    used: hot.used,
    budget: hot.budget,
    filter,
  };
}

/** The counts on the top border; a zero is left out unless it is the hot tally. */
export const summary = (counts: Record<GroupId, number>): string =>
  [
    `${counts.hot} hot`,
    counts.cold > 0 ? `${counts.cold} cold` : "",
    counts.stale > 0 ? `${counts.stale} stale` : "",
    counts.orphan > 0 ? `${counts.orphan} orphan` : "",
  ]
    .filter(Boolean)
    .join(" · ");

/** One group's header line. */
export const groupLine = (theme: Theme, width: number, group: Group): string =>
  theme.fg("accent", `── ${group.title} `) +
  theme.fg("borderMuted", "─".repeat(Math.max(0, width - visibleWidth(group.title) - 4)));

/** One entry as a list row: what is true of it, what it says, where it lives. */
export const rowLine = (theme: Theme, width: number, row: Row, selected: boolean): string => {
  const mark = theme.fg(MARK_COLOR[row.checks.status], STATUS_MARK[row.checks.status]);
  const priority = theme.fg(
    PRIORITY_COLOR(row.entry.priority),
    String(row.entry.priority).padStart(3),
  );
  const kind = theme.fg("dim", row.entry.kind.padEnd(KIND_WIDTH));
  const head = `${selected ? "▸" : " "} ${mark} ${priority}  ${kind}  `;
  const store = tag(row.entry);
  const room = Math.max(8, width - ROW_HEAD - visibleWidth(store) - 1);
  const statement = truncateToWidth(row.entry.statement, room, "…");
  const fill = " ".repeat(
    Math.max(1, width - ROW_HEAD - visibleWidth(statement) - visibleWidth(store)),
  );
  return head + (selected ? theme.bold(statement) : statement) + fill + theme.fg("dim", store);
};

/** Greedy word wrap; a word wider than the line is left whole and clipped later. */
export const wrap = (text: string, width: number): string[] => {
  const lines: string[] = [];
  let line = "";
  for (const word of text.split(/\s+/).filter(Boolean)) {
    const next = line ? `${line} ${word}` : word;
    if (line && visibleWidth(next) > width) {
      lines.push(line);
      line = word;
    } else line = next;
  }
  if (line) lines.push(line);
  return lines;
};

const labelled = (theme: Theme, width: number, label: string, text: string): string[] =>
  wrap(text, Math.max(8, width - LABEL_WIDTH)).map((line, index) =>
    index === 0
      ? theme.fg("dim", label.padEnd(LABEL_WIDTH)) + line
      : " ".repeat(LABEL_WIDTH) + line,
  );

/** The pane under the list: everything the entry says, and what backs it. */
export const detailLines = (theme: Theme, width: number, row: Row, model: Model): string[] => {
  const { entry, checks } = row;
  const where =
    row.group === "hot"
      ? `hot #${row.rank} of ${model.counts.hot}`
      : row.group === "stale"
        ? "stale · left out of the hot section"
        : row.group === "orphan"
          ? "orphan · not injected anywhere"
          : `cold · on disk, not in the ${model.budget}-char budget`;
  const head = `${entry.priority} ${entry.kind}`;
  const lines = [
    [
      theme.fg(MARK_COLOR[checks.status], STATUS_MARK[checks.status]),
      theme.fg("text", head) + theme.fg("dim", ` · ${tag(entry)} · ${where}`),
    ].join(" "),
    "",
  ];

  lines.push(...wrap(entry.statement, width));
  if (entry.detail) lines.push("", ...wrap(entry.detail, width));
  if (entry.whyNotDerivable)
    lines.push("", ...labelled(theme, width, "why", entry.whyNotDerivable));

  if (entry.citations.length > 0) {
    const cited = entry.citations.flatMap((citation, index) => {
      const check = checks.checks[index];
      const mark = check ? theme.fg(MARK_COLOR[check.status], STATUS_MARK[check.status]) : "  ";
      const label = theme.fg("dim", citation.kind.padEnd(LABEL_WIDTH - 2));
      const value = truncateToWidth(citation.value, Math.max(8, width - LABEL_WIDTH), "…");
      const note =
        check && check.note && check.note !== citation.value && check.status !== "verified"
          ? `  ${theme.fg("dim", check.note)}`
          : "";
      return [mark + " " + label + value + note];
    });
    lines.push("", ...cited);
  }

  if (row.note && row.group !== "stale") lines.push("", theme.fg("dim", row.note));
  const added = entry.added.slice(0, 10);
  lines.push("", theme.fg("dim", `${tilde(entry.file)} · added ${added}`));
  return lines;
};

/** The same rows without colour, for `/memory list` and a non-TUI session. */
export const plainRows = (model: Model): string[] =>
  model.groups.flatMap((group) => [
    `── ${group.title} ──`,
    ...group.rows.map(
      (row) =>
        `  ${STATUS_MARK[row.checks.status]} ${String(row.entry.priority).padStart(3)} ${row.entry.kind.padEnd(KIND_WIDTH)} ${row.entry.statement} · ${tag(row.entry)}`,
    ),
  ]);

/** What a session with nothing to show says instead of a list. */
export const emptyLines = (scope: Scope): string[] => [
  "No memories yet.",
  "",
  ...scope.visible.map((store) => `  ${store.origin}: ${tilde(store.dir)}`),
  "",
  "An agent saves one when a rule, a machine quirk or a correction",
  "would otherwise have to be learned again next session.",
];
