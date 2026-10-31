/**
 * The notes a session wrote under the agents' notes root, and how to open one.
 * Runtime imports stay Node built-ins, so `node --experimental-strip-types`
 * loads this outside pi.
 */
import { accessSync, constants, statSync } from "node:fs";
import { lstat, readdir } from "node:fs/promises";
import { homedir, userInfo } from "node:os";
import { basename, delimiter, isAbsolute, join, relative, resolve, sep } from "node:path";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { gitRoots } from "../../shared/git.ts";
import { writtenPath } from "../../shared/tools.ts";
import { formatAge } from "../lib/format.ts";

export const NOTES_ROOT = join(homedir(), ".local", "share", "agents");

/** Custom session entry naming a note this session wrote. */
export const NOTE_ENTRY = "agent-note";
export type NoteEntry = { path: string };

export type Note = { path: string; mtime: number };
/** A session's notes newest first, or the one fallback note when it wrote none. */
export type FoundNotes = { notes: Note[]; fallback: boolean };

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

const stat = (path: string): Note | undefined => {
  try {
    return { path, mtime: statSync(path).mtimeMs };
  } catch {
    return undefined;
  }
};

const newest = (notes: Note[]) => notes.sort((a, b) => b.mtime - a.mtime);

/**
 * The newest note anywhere under `dir`. Asynchronous and parallel: the root
 * holds thousands of directories, which a synchronous walk blocks the TUI on.
 */
const newestUnder = async (dir: string, root: string): Promise<Note | undefined> => {
  let best: Note | undefined;
  const walk = async (at: string): Promise<void> => {
    const entries = await readdir(at, { withFileTypes: true }).catch(() => []);
    await Promise.all(
      entries.map(async (entry) => {
        const path = join(at, entry.name);
        if (entry.isDirectory()) {
          if (entry.name !== "history" && !entry.name.startsWith(".")) await walk(path);
        } else if (entry.isFile() && isNote(path, root)) {
          const mtime = await lstat(path).then(
            (stats) => stats.mtimeMs,
            () => undefined,
          );
          if (mtime !== undefined && (!best || mtime > best.mtime)) best = { path, mtime };
        }
      }),
    );
  };
  await walk(dir);
  return best;
};

/**
 * This session's notes that still exist, newest first. With none, the newest
 * note under `<root>/<project>` (the main checkout's directory name, so every
 * worktree of a repository shares it), else the newest under `root`.
 */
export const findNotes = async (
  entries: readonly SessionEntry[],
  cwd: string,
  root = NOTES_ROOT,
): Promise<FoundNotes> => {
  const notes = newest(
    [...recordedNotes(entries)]
      .filter((path) => isNote(path, root))
      .flatMap((path) => stat(path) ?? []),
  );
  if (notes.length > 0) return { notes, fallback: false };
  const project = basename(gitRoots(cwd).main ?? cwd);
  const latest = (await newestUnder(join(root, project), root)) ?? (await newestUnder(root, root));
  return { notes: latest ? [latest] : [], fallback: true };
};

/**
 * Picker labels, `<dir>/<file> · <age>`: two path segments, or as many more
 * as it takes for no two notes to share one.
 */
export const noteLabels = (notes: readonly Note[], root = NOTES_ROOT, now = Date.now()) => {
  const parts = notes.map((note) => relative(root, note.path).split(sep));
  const depth = parts.map((segments) => Math.min(2, segments.length));
  const names = () => parts.map((segments, i) => segments.slice(-depth[i]).join("/"));
  for (let widened = true; widened; ) {
    widened = false;
    const shown = names();
    shown.forEach((name, i) => {
      if (shown.indexOf(name) !== shown.lastIndexOf(name) && depth[i] < parts[i].length) {
        depth[i]++;
        widened = true;
      }
    });
  }
  return names().map((name, i) => `${name} · ${formatAge(now - notes[i].mtime, "now")}`);
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

/** The command that shows a note: the opener, else VS Code, else undefined. */
export const noteOpener = (
  path: string,
  env: NodeJS.ProcessEnv = process.env,
): { command: string; args: string[] } | undefined => {
  const opener = openerCandidates(env).find(executable);
  if (opener) return { command: opener, args: [path] };
  const code = searchPath(env)
    .map((dir) => join(dir, "code"))
    .find(executable);
  return code ? { command: code, args: ["--reuse-window", path] } : undefined;
};
