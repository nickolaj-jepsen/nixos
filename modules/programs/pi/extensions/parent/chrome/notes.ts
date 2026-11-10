/**
 * The checkout's notes, for `/open plan`: the Markdown under its store
 * (`.agents/store`), and the opener that hands one to the editor.
 * Runtime imports stay Node built-ins, so `node --experimental-strip-types`
 * loads this outside pi.
 */
import { accessSync, constants, lstatSync, readdirSync, realpathSync, statSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { delimiter, dirname, join } from "node:path";

/** `name` is the path below the store. */
export type Note = { path: string; name: string; at: number };

/**
 * The store of the checkout `cwd` is in, by its real path. Throws when the
 * nearest link dangles, as it does until something writes a note; undefined
 * when no directory above has one.
 */
const storeOf = (cwd: string) => {
  for (let dir = cwd; ; dir = dirname(dir)) {
    const link = join(dir, ".agents", "store");
    if (lstatSync(link, { throwIfNoEntry: false })) return realpathSync(link);
    if (dir === dirname(dir)) return undefined;
  }
};

const notesUnder = (dir: string, below = ""): Note[] =>
  readdirSync(dir, { withFileTypes: true }).flatMap((entry): Note[] => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      // Superseded copies, the artefacts a note names, and dot dirs are not notes.
      const skipped =
        entry.name === "history" || entry.name === "files" || entry.name.startsWith(".");
      return skipped ? [] : notesUnder(path, `${below}${entry.name}/`);
    }
    return entry.isFile() && entry.name.endsWith(".md")
      ? [{ path, name: below + entry.name, at: statSync(path).mtimeMs }]
      : [];
  });

/** The Markdown notes of the checkout's store, newest first. */
export const storeNotes = (cwd: string): Note[] => {
  try {
    const store = storeOf(cwd);
    return store ? notesUnder(store).sort((a, b) => b.at - a.at) : [];
  } catch {
    return [];
  }
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

/** The command that opens a note: the opener, else undefined, so a caller can fall back. */
export const noteOpener = (
  path: string,
  env: NodeJS.ProcessEnv = process.env,
): { command: string; args: string[] } | undefined => {
  const opener = openerCandidates(env).find(executable);
  return opener ? { command: opener, args: [path] } : undefined;
};
