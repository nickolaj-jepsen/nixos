/**
 * The agent notes a session wrote under the notes root, as menu rows; the
 * shared opener (`agent-note-open`) shows each one.
 */
import type { Menu, Row } from "../types";

export const OPENER = "agent-note-open";

// MultiEdit is gone from current builds but still in older transcripts.
const WRITE_TOOLS = new Set(["Write", "Edit", "MultiEdit"]);

export type ToolUse = { tool: string; input: Record<string, unknown>; isError?: true };

export type Note = { path: string; mtimeMs: number };

/** An absolute path with `.` and `..` folded; undefined for a relative one. */
export const normalize = (path: string): string | undefined => {
  if (!path.startsWith("/")) return undefined;
  const out: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") out.pop();
    else out.push(part);
  }
  return `/${out.join("/")}`;
};

/** The path's segments below `root`, or undefined when it is not a note there. */
export const noteSegments = (root: string, path: string): string[] | undefined => {
  if (!path.startsWith(`${root}/`)) return undefined;
  const segments = path.slice(root.length + 1).split("/");
  const name = segments[segments.length - 1] ?? "";
  // history/ holds superseded versions, PLAN.prev.md is annotate-plan's diff base, dot dirs are archives.
  if (!name.endsWith(".md") || name === "PLAN.prev.md") return undefined;
  if (segments.some((s) => s === "history" || s.startsWith("."))) return undefined;
  return segments;
};

/** Notes the session's write tools touched without error, the last one touched first. */
export const sessionNotes = (uses: readonly ToolUse[], root: string): string[] => {
  const seen = new Set<string>();
  const out: string[] = [];
  for (let i = uses.length - 1; i >= 0; i--) {
    const use = uses[i];
    if (!use || use.isError || !WRITE_TOOLS.has(use.tool)) continue;
    const raw = use.input.file_path;
    const path = typeof raw === "string" ? normalize(raw) : undefined;
    if (!path || seen.has(path) || !noteSegments(root, path)) continue;
    seen.add(path);
    out.push(path);
  }
  return out;
};

/** The newest note under `<root>/<project>/`, else the newest anywhere under the root. */
export const fallbackNote = (
  notes: readonly Note[],
  root: string,
  project: string,
): Note | undefined => {
  const newest = (list: readonly Note[]) =>
    list.reduce<Note | undefined>((a, b) => (!a || b.mtimeMs > a.mtimeMs ? b : a), undefined);
  return newest(notes.filter((n) => n.path.startsWith(`${root}/${project}/`))) ?? newest(notes);
};

/** `<dir>/<file>` for each path, with more parent dirs where two would read the same. */
export const labels = (root: string, paths: readonly string[]): string[] => {
  const segments = paths.map((p) => p.slice(root.length + 1).split("/"));
  const depth = segments.map((s) => Math.min(2, s.length));
  for (;;) {
    const text = segments.map((s, i) => s.slice(-(depth[i] ?? 1)).join("/"));
    const counts = new Map<string, number>();
    for (const t of text) counts.set(t, (counts.get(t) ?? 0) + 1);
    let grew = false;
    text.forEach((t, i) => {
      if ((counts.get(t) ?? 0) > 1 && (depth[i] ?? 0) < (segments[i]?.length ?? 0)) {
        depth[i] = (depth[i] ?? 0) + 1;
        grew = true;
      }
    });
    if (!grew) return text;
  }
};

export const age = (ms: number): string => {
  const minutes = Math.floor(Math.max(0, ms) / 60_000);
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 24 ? `${hours}h` : `${Math.floor(hours / 24)}d`;
};

/**
 * The notes as rows, each started by `opener` (the argv before the path), or
 * naming the path when nothing can show it.
 */
export const notesMenu = ({
  root,
  notes,
  isFallback,
  opener,
  now,
}: {
  root: string;
  notes: readonly Note[];
  isFallback: boolean;
  opener: string[] | undefined;
  now: number;
}): Menu => {
  if (notes.length === 0)
    return { kind: "notes", title: "Notes", rows: [], error: `No notes under ${root}.` };
  const names = labels(
    root,
    notes.map((n) => n.path),
  );
  const rows = notes.map(
    (note, i): Row => ({
      id: note.path,
      label: names[i] ?? note.path,
      description: age(now - note.mtimeMs),
      ...(opener
        ? { action: { kind: "launch", argv: [...opener, note.path] } }
        : { unavailable: `no viewer: ${note.path}` }),
    }),
  );
  return {
    kind: "notes",
    title: "Notes",
    context: isFallback ? "none this session, the newest" : "this session",
    rows,
    preferred: rows[0]?.id,
  };
};
