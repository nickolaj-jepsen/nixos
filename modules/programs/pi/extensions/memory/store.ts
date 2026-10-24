/**
 * Memory stores on disk: one Markdown file per entry, grouped into a global
 * store and one store per git worktree root. The Markdown files are the only
 * persistent representation; everything else is derived when a session starts.
 *
 * A worktree session sees its own store (writable), the main checkout's store
 * and the global store. A store whose worktree root has gone (after `wt clean`)
 * is an orphan: never injected, only offered for promotion or deletion.
 */
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";
import { getAgentDir, withFileMutationQueue } from "@earendil-works/pi-coding-agent";
import { parse, serialize, type FrontmatterValue } from "./frontmatter.ts";

export const KINDS = ["rule", "preference", "environment", "gotcha", "reference"] as const;
export type Kind = (typeof KINDS)[number];

export const CITATION_KINDS = [
  "path",
  "symbol",
  "snippet",
  "command",
  "quote",
  "url",
  "session",
] as const;
export type CitationKind = (typeof CITATION_KINDS)[number];
export type Citation = { kind: CitationKind; value: string; path?: string };

export type Origin = "worktree" | "main" | "global" | "orphan";

export type Store = {
  origin: Origin;
  dir: string;
  /** Checkout the store belongs to; relative citations resolve against it. Unset for global. */
  root?: string;
  label: string;
  writable: boolean;
};

export type Entry = {
  id: string;
  kind: Kind;
  priority: number;
  added: string;
  updated: string;
  sourceSession?: string;
  whyNotDerivable: string;
  citations: Citation[];
  /** First body paragraph, one line; what the hot section shows. */
  statement: string;
  /** Rest of the body. */
  detail: string;
  file: string;
  store: Store;
  /** Frontmatter keys this module does not own, kept on rewrite. */
  extra: Record<string, FrontmatterValue>;
};

export type Scope = {
  cwd: string;
  /** Worktree root of the cwd, unset outside git. */
  root?: string;
  /** Main checkout of the repo, unset outside git. */
  main?: string;
  isWorktree: boolean;
  /** The store `memory_save` writes project entries to. */
  project?: Store;
  global: Store;
  /** Stores the session reads, in tie-break order. */
  visible: Store[];
  orphans: Store[];
};

export const STATEMENT_MAX = 200;
const ID_MAX = 48;
const META = ".store.json";

type StoreMeta = { root: string; main?: string; kind: "main" | "worktree"; created: string };

/** Root of all memory stores; `PI_MEMORY_DIR` overrides it. */
export const memoryDir = () => process.env.PI_MEMORY_DIR ?? join(getAgentDir(), "memory");

const real = (path: string) => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};

const storeKey = (root: string) =>
  createHash("sha256").update(real(root)).digest("hex").slice(0, 16);

const git = (cwd: string, args: string[]) => {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      timeout: 5_000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return undefined;
  }
};

/** Worktree root and main checkout of `cwd`, both unset outside git. */
export function gitRoots(cwd: string): { root?: string; main?: string } {
  const out = git(cwd, [
    "rev-parse",
    "--path-format=absolute",
    "--show-toplevel",
    "--git-common-dir",
  ]);
  if (!out) return {};
  const [top, common] = out.split("\n");
  if (!top) return {};
  // A bare common dir has no main checkout; treat the worktree as its own main.
  const main = common && basename(common) === ".git" ? dirname(common) : top;
  return { root: real(top), main: real(main) };
}

const readMeta = (dir: string): StoreMeta | undefined => {
  try {
    return JSON.parse(readFileSync(join(dir, META), "utf8")) as StoreMeta;
  } catch {
    return undefined;
  }
};

/** Resolves the stores a session in `cwd` reads and writes. */
export function resolveScope(cwd: string): Scope {
  const base = memoryDir();
  const global: Store = {
    origin: "global",
    dir: join(base, "global"),
    label: "global",
    writable: true,
  };
  const { root, main } = gitRoots(cwd);
  if (!root || !main) return { cwd, isWorktree: false, global, visible: [global], orphans: [] };

  const isWorktree = root !== main;
  const projects = join(base, "projects");
  const mainStore: Store = {
    origin: "main",
    dir: join(projects, storeKey(main)),
    root: main,
    label: basename(main),
    writable: !isWorktree,
  };
  const wtStore: Store | undefined = isWorktree
    ? {
        origin: "worktree",
        dir: join(projects, storeKey(root)),
        root,
        label: basename(root),
        writable: true,
      }
    : undefined;

  const orphans: Store[] = [];
  if (existsSync(projects)) {
    for (const key of readdirSync(projects)) {
      const dir = join(projects, key);
      const meta = readMeta(dir);
      if (!meta || meta.kind !== "worktree" || meta.main !== main || existsSync(meta.root))
        continue;
      orphans.push({
        origin: "orphan",
        dir,
        root: meta.root,
        label: basename(meta.root),
        writable: false,
      });
    }
  }

  const project = wtStore ?? mainStore;
  return {
    cwd,
    root,
    main,
    isWorktree,
    project,
    global,
    visible: wtStore ? [wtStore, mainStore, global] : [mainStore, global],
    orphans,
  };
}

const str = (v: FrontmatterValue | undefined) =>
  typeof v === "string" ? v : v == null ? undefined : String(v);
const num = (v: FrontmatterValue | undefined, fallback: number) => {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : fallback;
};

const OWNED = new Set([
  "id",
  "kind",
  "priority",
  "added",
  "updated",
  "source_session",
  "why_not_derivable",
  "citations",
]);

function citationsOf(v: FrontmatterValue | undefined): Citation[] {
  if (!Array.isArray(v)) return [];
  const out: Citation[] = [];
  for (const item of v) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const kind = str(item.kind) as CitationKind | undefined;
    const value = str(item.value);
    if (!kind || !value || !CITATION_KINDS.includes(kind)) continue;
    const path = str(item.path);
    out.push(path ? { kind, value, path } : { kind, value });
  }
  return out;
}

/** Splits a body into its one-line statement and the remaining detail. */
function splitBody(body: string): { statement: string; detail: string } {
  const trimmed = body.trim();
  const cut = trimmed.search(/\n\s*\n/);
  const head = cut === -1 ? trimmed : trimmed.slice(0, cut);
  return {
    statement: head.replace(/\s+/g, " ").trim(),
    detail: cut === -1 ? "" : trimmed.slice(cut).trim(),
  };
}

/** Parses one memory file; returns undefined for a file with no statement. */
export function parseEntry(text: string, file: string, store: Store): Entry | undefined {
  const { data, body } = parse(text);
  const { statement, detail } = splitBody(body);
  if (!statement) return undefined;
  const extra: Record<string, FrontmatterValue> = {};
  for (const [key, val] of Object.entries(data)) if (!OWNED.has(key)) extra[key] = val;
  const kind = str(data.kind) as Kind | undefined;
  const added = str(data.added) ?? "";
  return {
    id: str(data.id) ?? basename(file, ".md"),
    kind: kind && KINDS.includes(kind) ? kind : "reference",
    priority: Math.max(0, Math.min(100, num(data.priority, 50))),
    added,
    updated: str(data.updated) ?? added,
    sourceSession: str(data.source_session),
    whyNotDerivable: str(data.why_not_derivable) ?? "",
    citations: citationsOf(data.citations),
    statement,
    detail,
    file,
    store,
    extra,
  };
}

/** Renders an entry back to its file text. */
export function renderEntry(entry: Entry): string {
  const body = entry.detail ? `${entry.statement}\n\n${entry.detail}` : entry.statement;
  return serialize(
    {
      id: entry.id,
      kind: entry.kind,
      priority: entry.priority,
      added: entry.added,
      updated: entry.updated,
      source_session: entry.sourceSession,
      why_not_derivable: entry.whyNotDerivable,
      citations: entry.citations,
      ...entry.extra,
    },
    body,
  );
}

/** Every parseable entry in `store`; unparseable files are reported in `skipped`. */
export function loadStore(store: Store): { entries: Entry[]; skipped: string[] } {
  const entries: Entry[] = [];
  const skipped: string[] = [];
  if (!existsSync(store.dir)) return { entries, skipped };
  for (const name of readdirSync(store.dir).sort()) {
    if (!name.endsWith(".md")) continue;
    const file = join(store.dir, name);
    try {
      const entry = parseEntry(readFileSync(file, "utf8"), file, store);
      if (entry) entries.push(entry);
      else skipped.push(file);
    } catch {
      skipped.push(file);
    }
  }
  return { entries, skipped };
}

const cache = new Map<string, Entry[]>();

/** `loadStore` with a cache that lives until the extension invalidates it after a write. */
export function loadStoreCached(store: Store): Entry[] {
  let entries = cache.get(store.dir);
  if (!entries) {
    entries = loadStore(store).entries;
    cache.set(store.dir, entries);
  }
  return entries;
}

/** Forgets the cached entries of `store`. */
export const invalidateStore = (store: Store) => void cache.delete(store.dir);

/** Drops every cached store, e.g. when a session starts. */
export const invalidateAll = () => cache.clear();

/** Lowercase kebab-case id derived from `text`, at most ID_MAX chars. */
export function slugify(text: string): string {
  const slug = text
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^\w\s-]/g, "")
    .replace(/[\s_-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  const cut = slug
    .slice(0, ID_MAX)
    .replace(/-[^-]*$/, (tail) => (slug.length > ID_MAX ? "" : tail));
  return cut.replace(/-+$/g, "") || "memory";
}

/** `id`, or `id-2`, `id-3`, … — the first that has no file in `store`. */
export function freeId(store: Store, id: string): string {
  let candidate = id;
  for (let n = 2; existsSync(join(store.dir, `${candidate}.md`)); n++) candidate = `${id}-${n}`;
  return candidate;
}

function ensureStore(store: Store) {
  mkdirSync(store.dir, { recursive: true });
  if (store.origin === "global" || !store.root || existsSync(join(store.dir, META))) return;
  const main = store.origin === "main" ? store.root : gitRoots(store.root).main;
  const meta: StoreMeta = {
    root: store.root,
    main,
    kind: store.origin === "worktree" ? "worktree" : "main",
    created: new Date().toISOString(),
  };
  writeFileSync(join(store.dir, META), `${JSON.stringify(meta, null, 2)}\n`);
}

const atomicWrite = (file: string, text: string) => {
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, text);
  renameSync(tmp, file);
};

/** Writes `entry` to its file, creating the store on first use. */
export async function writeEntry(entry: Entry): Promise<void> {
  ensureStore(entry.store);
  await withFileMutationQueue(entry.file, async () => atomicWrite(entry.file, renderEntry(entry)));
  invalidateStore(entry.store);
}

/** Re-reads `file`, applies `change` to the entry in it, and writes it back. */
export async function updateEntryFile(
  file: string,
  store: Store,
  change: (entry: Entry) => void,
): Promise<Entry | undefined> {
  return withFileMutationQueue(file, async () => {
    if (!existsSync(file)) return undefined;
    const entry = parseEntry(readFileSync(file, "utf8"), file, store);
    if (!entry) return undefined;
    change(entry);
    atomicWrite(file, renderEntry(entry));
    return entry;
  }).then((result) => {
    invalidateStore(store);
    return result;
  });
}

/** Deletes an entry's file, and its store dir once nothing but metadata is left. */
export async function deleteEntry(entry: Entry): Promise<void> {
  await withFileMutationQueue(entry.file, async () => rmSync(entry.file, { force: true }));
  invalidateStore(entry.store);
  pruneStore(entry.store);
}

/** Removes a store dir that holds no entries. */
export function pruneStore(store: Store) {
  if (!existsSync(store.dir)) return;
  const left = readdirSync(store.dir).filter((name) => name !== META);
  if (left.length === 0) rmSync(store.dir, { recursive: true, force: true });
}

/** Copies `entry` into `target` under a free id, keeping its provenance. */
export async function copyEntry(entry: Entry, target: Store): Promise<Entry> {
  const id = freeId(target, entry.id);
  const copy: Entry = {
    ...entry,
    id,
    file: join(target.dir, `${id}.md`),
    store: target,
    updated: new Date().toISOString(),
    extra: { ...entry.extra, promoted_from: entry.store.root ?? entry.store.label },
  };
  await writeEntry(copy);
  return copy;
}
