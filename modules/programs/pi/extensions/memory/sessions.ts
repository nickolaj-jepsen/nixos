/**
 * Pull-only search over raw pi session transcripts. Episodes stay out of the
 * prompt: they are cited when asked for, never injected, so an old conversation
 * cannot quietly become a fact.
 *
 * A session's label and summary, which chrome's identity keeps current, are
 * searched too: they say what a whole session was about where any one message
 * only says what was said, so a match there ranks above a message.
 *
 * Default scope is the current repo — its main checkout plus every worktree,
 * including ones `wt clean` already removed — because a discarded PoC is still
 * honest history even when its conclusions are not worth remembering.
 */
import { open, readdir, readFile, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { homedir } from "node:os";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { IDENTITY_ENTRY } from "../lib/sidecar.ts";
import { gitRoots } from "./store.ts";

export type SessionScope = "repo" | "all";
export type SessionHit = {
  session: string;
  cwd: string;
  timestamp: string;
  role: string;
  excerpt: string;
  file: string;
  score: number;
  /** The session's label when it had one. */
  label?: string;
};

const MAX_FILES = 400;
const MAX_FILE_BYTES = 8 * 1024 * 1024;
const MAX_LINE_BYTES = 512 * 1024;
const EXCERPT_CHARS = 320;

type Header = { id?: string; cwd?: string; timestamp?: string };
// As JSON.stringify writes it; a message quoting the name has its quotes escaped.
const IDENTITY_LINE = `"customType":"${IDENTITY_ENTRY}"`;
type Card = { label?: string; summary?: string; tags: string[]; timestamp: string };

/** The identity record a transcript line holds, if it is one. */
function identityCard(entry: unknown): Card | undefined {
  const row = entry as { type?: string; customType?: string; timestamp?: string; data?: unknown };
  if (row?.type !== "custom" || row.customType !== IDENTITY_ENTRY) return undefined;
  const data = row.data as { text?: unknown; summary?: unknown; tags?: unknown } | undefined;
  return {
    label: typeof data?.text === "string" && data.text ? data.text : undefined,
    summary: typeof data?.summary === "string" && data.summary ? data.summary : undefined,
    tags: Array.isArray(data?.tags)
      ? data.tags.filter((tag): tag is string => typeof tag === "string")
      : [],
    timestamp: row.timestamp ?? "",
  };
}

/** First line of a session file, which records its cwd, id and start time. */
async function header(file: string): Promise<Header | undefined> {
  const handle = await open(file, "r").catch(() => undefined);
  if (!handle) return undefined;
  try {
    const buffer = Buffer.alloc(8192);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    const newline = buffer.subarray(0, bytesRead).indexOf(0x0a);
    const parsed = JSON.parse(
      buffer.subarray(0, newline === -1 ? bytesRead : newline).toString("utf8"),
    ) as Header & {
      type?: string;
    };
    return parsed.type === "session" ? parsed : undefined;
  } catch {
    return undefined;
  } finally {
    await handle.close();
  }
}

const within = (cwd: string, dirs: string[]) =>
  dirs.some((dir) => cwd === dir || cwd.startsWith(`${dir}/`));

/** Directories whose sessions belong to the repo containing `cwd`. */
export function repoCwds(cwd: string): string[] {
  const { root, main } = gitRoots(cwd);
  if (!root || !main) return [cwd];
  const worktreeRoot = process.env.WT_WORKTREE_ROOT ?? join(homedir(), "worktrees");
  return [main, join(worktreeRoot, basename(main)), join(main, ".claude", "worktrees")];
}

/** Every session file under the agent dir, newest first, subagent transcripts only on request. */
async function sessionFiles(includeSubagents: boolean): Promise<string[]> {
  const root = join(getAgentDir(), "sessions");
  const out: string[] = [];
  const walk = async (dir: string, depth: number) => {
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.name.endsWith(".jsonl")) out.push(path);
      else if ((entry.isDirectory() || entry.isSymbolicLink()) && (depth === 0 || includeSubagents))
        await walk(path, depth + 1);
    }
  };
  await walk(root, 0);
  // Basenames start with the session's ISO start time.
  return out.sort((a, b) => basename(b).localeCompare(basename(a)));
}

const textOf = (content: unknown): string => {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    if (block && typeof block === "object" && (block as { type?: string }).type === "text") {
      const text = (block as { text?: unknown }).text;
      if (typeof text === "string") parts.push(text);
    }
  }
  return parts.join("\n");
};

/** The human-readable line of a transcript entry, if it has one worth searching. */
function entryText(entry: unknown): { role: string; text: string; timestamp: string } | undefined {
  const row = entry as {
    type?: string;
    timestamp?: string;
    message?: { role?: string; content?: unknown };
  };
  if (row?.type !== "message" || !row.message) return undefined;
  const role = row.message.role ?? "";
  if (role !== "user" && role !== "assistant") return undefined;
  const text = textOf(row.message.content).trim();
  if (text.length < 8) return undefined;
  return { role, text, timestamp: row.timestamp ?? "" };
}

function excerpt(text: string, needle: string): string {
  const flat = text.replace(/\s+/g, " ");
  const at = flat.toLowerCase().indexOf(needle);
  if (at < 0) return flat.slice(0, EXCERPT_CHARS);
  const start = Math.max(0, at - Math.floor(EXCERPT_CHARS / 3));
  const cut = flat.slice(start, start + EXCERPT_CHARS);
  return `${start > 0 ? "…" : ""}${cut}${start + EXCERPT_CHARS < flat.length ? "…" : ""}`;
}

export type SessionQuery = {
  query: string;
  scope?: SessionScope;
  includeSubagents?: boolean;
  /** Skips sessions started before this ISO date. */
  since?: string;
  limit?: number;
  cwd: string;
  currentSessionFile?: string;
  signal?: AbortSignal;
};

/** Ranked transcript excerpts matching `query`, from the newest MAX_FILES sessions in scope. */
export async function searchSessions(
  query: SessionQuery,
): Promise<{ hits: SessionHit[]; scanned: number; skipped: number }> {
  const terms = [
    ...new Set(
      query.query
        .toLowerCase()
        .split(/\s+/)
        .filter((term) => term.length > 1),
    ),
  ];
  if (terms.length === 0) return { hits: [], scanned: 0, skipped: 0 };
  const family = repoCwds(query.cwd);
  const since = Date.parse(query.since ?? "");
  const files = (await sessionFiles(query.includeSubagents ?? false)).filter(
    (file) => file !== query.currentSessionFile,
  );
  const hits: SessionHit[] = [];
  const seen = new Set<string>();
  let scanned = 0;
  let skipped = 0;

  for (const [index, file] of files.entries()) {
    if (query.signal?.aborted) break;
    if (scanned >= MAX_FILES) {
      skipped += files.length - index;
      break;
    }
    const head = await header(file);
    if (!head?.cwd) continue;
    if ((query.scope ?? "repo") === "repo" && !within(head.cwd, family)) continue;
    if (!Number.isNaN(since) && !(Date.parse(head.timestamp ?? "") >= since)) continue;
    let raw: string;
    try {
      if ((await stat(file)).size > MAX_FILE_BYTES) {
        skipped++;
        continue;
      }
      raw = await readFile(file, "utf8");
    } catch {
      skipped++;
      continue;
    }
    scanned++;
    const lower = raw.toLowerCase();
    if (!terms.some((term) => lower.includes(term))) continue;
    const session = head.id ?? basename(file, ".jsonl");
    const found: SessionHit[] = [];
    let card: Card | undefined;

    for (const rawLine of raw.split("\n")) {
      if (rawLine.length > MAX_LINE_BYTES || !rawLine.startsWith("{")) continue;
      // Read whether or not it matches: every hit of the session carries its label.
      if (rawLine.includes(IDENTITY_LINE)) {
        try {
          card = identityCard(JSON.parse(rawLine)) ?? card;
        } catch {}
        continue;
      }
      const lowered = rawLine.toLowerCase();
      if (!terms.some((term) => lowered.includes(term))) continue;
      let entry: unknown;
      try {
        entry = JSON.parse(rawLine);
      } catch {
        continue;
      }
      const line = entryText(entry);
      if (!line) continue;
      const flat = line.text.replace(/\s+/g, " ").toLowerCase();
      const matched = terms.filter((term) => flat.includes(term));
      if (matched.length === 0) continue;
      const snippet = excerpt(line.text, matched[0]);
      const key = snippet.slice(0, 120);
      if (seen.has(key)) continue;
      seen.add(key);
      found.push({
        session,
        cwd: head.cwd,
        timestamp: line.timestamp,
        role: line.role,
        excerpt: snippet,
        file,
        score: matched.length + (flat.includes(query.query.toLowerCase()) ? 1 : 0),
      });
    }

    const about = card
      ? [card.label, card.summary, card.tags.length ? `(${card.tags.join(", ")})` : undefined]
          .filter(Boolean)
          .join(" — ")
      : "";
    const aboutLower = about.toLowerCase();
    const aboutMatched = terms.filter((term) => aboutLower.includes(term));
    if (card && aboutMatched.length > 0) {
      found.push({
        session,
        cwd: head.cwd,
        timestamp: card.timestamp,
        role: "summary",
        excerpt: about,
        file,
        score: aboutMatched.length + (aboutLower.includes(query.query.toLowerCase()) ? 1 : 0) + 1,
      });
    }
    for (const hit of found) hits.push(card?.label ? { ...hit, label: card.label } : hit);
  }
  hits.sort((a, b) => b.score - a.score || b.timestamp.localeCompare(a.timestamp));
  return { hits: hits.slice(0, query.limit ?? 5), scanned, skipped };
}
