/**
 * The checkout's notes as menu rows: the Markdown under its store
 * (`.agents/store`), newest first. The shared opener (`agent-note-open`) hands
 * each one to the editor.
 */
import type { Menu, Row } from "../types";

export const OPENER = "agent-note-open";
/** The checkout's link into the note store. */
export const STORE = ".agents/store";

/** `name` is the path below the store. */
export type Note = { path: string; name: string; at: number };

/** Whether the listing goes into a store directory: not superseded copies, artefacts or dot dirs. */
export const holdsNotes = (dir: string) =>
  dir !== "history" && dir !== "files" && !dir.startsWith(".");

export const age = (ms: number): string => {
  const minutes = Math.floor(Math.max(0, ms) / 60_000);
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 24 ? `${hours}h` : `${Math.floor(hours / 24)}d`;
};

/**
 * The notes as rows, newest first, each started by `opener` (the argv before
 * the path), or naming the path when nothing can open it.
 */
export const notesMenu = ({
  notes,
  opener,
  now,
}: {
  notes: readonly Note[];
  opener: string[] | undefined;
  now: number;
}): Menu => {
  if (notes.length === 0)
    return { kind: "notes", title: "Notes", rows: [], error: "No notes yet." };
  const rows = [...notes]
    .sort((a, b) => b.at - a.at)
    .map(
      (note): Row => ({
        id: note.path,
        label: note.name,
        description: age(now - note.at),
        ...(opener
          ? { action: { kind: "launch", argv: [...opener, note.path] } }
          : { unavailable: `no editor: ${note.path}` }),
      }),
    );
  return { kind: "notes", title: "Notes", rows, preferred: rows[0]?.id };
};
