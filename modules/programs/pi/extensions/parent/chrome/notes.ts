/**
 * What agent-hub can't read for itself about notes: the record of a write,
 * which a nested call's transcript may not name, and how to open one when the
 * bar has no reader. The hub says which notes a session has (`Hub.notes`).
 * Runtime imports stay Node built-ins, so `node --experimental-strip-types`
 * loads this outside pi.
 */
import { accessSync, constants, statSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { basename, delimiter, isAbsolute, join, relative, resolve, sep } from "node:path";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { writtenPath } from "../../shared/tools.ts";

export const NOTES_ROOT = join(homedir(), ".local", "share", "agents");

/** Custom session entry naming a note this session wrote. */
export const NOTE_ENTRY = "agent-note";
export type NoteEntry = { path: string };

/** Markdown under `root`, minus superseded copies (`history/`, annotate-plan's `PLAN.prev.md`) and dot dirs. */
const isNote = (path: string, root: string) => {
  const rel = relative(root, path);
  if (!rel || rel.startsWith("..") || isAbsolute(rel)) return false;
  const parts = rel.split(sep);
  return (
    path.endsWith(".md") &&
    basename(path) !== "PLAN.prev.md" &&
    !parts.slice(0, -1).some((part) => part === "history" || part.startsWith("."))
  );
};

const expandPath = (path: string) => {
  const bare = path.startsWith("@") ? path.slice(1) : path;
  return bare === "~" || bare.startsWith("~/") ? join(homedir(), bare.slice(1)) : bare;
};

/** The note a successful write or edit touched, as an absolute path; undefined for any other call. */
export const writtenNote = (
  event: { toolName: string; input: unknown; isError: boolean },
  cwd: string,
  root = NOTES_ROOT,
) => {
  if (event.isError) return undefined;
  const path = writtenPath(event.toolName, event.input);
  if (path === undefined) return undefined;
  const absolute = resolve(cwd, expandPath(path));
  return isNote(absolute, root) ? absolute : undefined;
};

/** Paths of the `NOTE_ENTRY` records on a branch, oldest first. */
export const recordedNotes = (entries: readonly SessionEntry[]) => {
  const paths = new Set<string>();
  for (const entry of entries) {
    if (entry.type !== "custom" || entry.customType !== NOTE_ENTRY) continue;
    const path = (entry.data as Partial<NoteEntry> | undefined)?.path;
    if (typeof path === "string") paths.add(path);
  }
  return paths;
};

const OPENER = "agent-note-open";

const executable = (path: string) => {
  try {
    accessSync(path, constants.X_OK);
    return statSync(path).isFile();
  } catch {
    return false;
  }
};

const searchPath = (env: NodeJS.ProcessEnv) => (env.PATH ?? "").split(delimiter).filter(Boolean);

/**
 * Where the opener may be, in the order tried: pi rebuilds PATH for what it
 * starts, so the profiles are named by absolute path after PATH.
 */
export const openerCandidates = (env: NodeJS.ProcessEnv = process.env) => [
  ...searchPath(env).map((dir) => join(dir, OPENER)),
  join("/etc/profiles/per-user", env.USER ?? userInfo().username, "bin", OPENER),
  join(env.HOME ?? homedir(), ".nix-profile", "bin", OPENER),
];

/** The command that shows a note: the opener, else undefined, so a caller can fall back. */
export const noteOpener = (
  path: string,
  env: NodeJS.ProcessEnv = process.env,
): { command: string; args: string[] } | undefined => {
  const opener = openerCandidates(env).find(executable);
  return opener ? { command: opener, args: [path] } : undefined;
};
