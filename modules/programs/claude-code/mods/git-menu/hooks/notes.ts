/**
 * A session's notes as menu rows, for where the bar's reader can't show them.
 * agent-hub knows which notes a session has, its subagents' included; the
 * shared opener (`agent-note-open`) shows each one.
 */
import type { Menu, Row } from "../types";

export const OPENER = "agent-note-open";
export const HUB = "agent-hub";

export type Note = { path: string; name: string; group: string; at: number };

/** The lines of `agent-hub notes --json`; a line that isn't a note is skipped. */
export const parseNotes = (stdout: string): Note[] =>
  stdout.split("\n").flatMap((line) => {
    if (!line.trim()) return [];
    try {
      const note = JSON.parse(line) as Partial<Note> | null;
      return typeof note?.path === "string" && typeof note.name === "string"
        ? [
            {
              path: note.path,
              name: note.name,
              group: note.group ?? "project",
              at: note.at ?? 0,
            },
          ]
        : [];
    } catch {
      return [];
    }
  });

export const age = (ms: number): string => {
  const minutes = Math.floor(Math.max(0, ms) / 60_000);
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 24 ? `${hours}h` : `${Math.floor(hours / 24)}d`;
};

/**
 * The notes as rows, each started by `opener` (the argv before the path), or
 * naming the path when nothing can show it. Undefined notes: the hub didn't say.
 */
export const notesMenu = ({
  notes,
  opener,
  now,
}: {
  notes: readonly Note[] | undefined;
  opener: string[] | undefined;
  now: number;
}): Menu => {
  if (!notes)
    return {
      kind: "notes",
      title: "Notes",
      rows: [],
      error: `${HUB} isn't running, and it is what knows the notes.`,
    };
  if (notes.length === 0)
    return { kind: "notes", title: "Notes", rows: [], error: "No notes yet." };
  const rows = notes.map(
    (note): Row => ({
      id: note.path,
      label: note.name,
      description:
        note.group === "written" ? age(now - note.at) : `${age(now - note.at)} ${note.group}`,
      ...(opener
        ? { action: { kind: "launch", argv: [...opener, note.path] } }
        : { unavailable: `no viewer: ${note.path}` }),
    }),
  );
  return { kind: "notes", title: "Notes", rows, preferred: rows[0]?.id };
};
