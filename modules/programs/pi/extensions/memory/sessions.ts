/**
 * Pull-only search over raw pi session transcripts. Episodes stay out of the
 * prompt: they are cited when asked for, never injected, so an old conversation
 * cannot quietly become a fact.
 *
 * Default scope is the current repo — its main checkout plus every worktree,
 * including ones `wt clean` already removed — because a discarded PoC is still
 * honest history even when its conclusions are not worth remembering.
 */
import { closeSync, openSync, readdirSync, readFileSync, readSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import { homedir } from "node:os";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
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
};

const MAX_FILES = 400;
const MAX_FILE_BYTES = 8 * 1024 * 1024;
const MAX_LINE_BYTES = 512 * 1024;
const EXCERPT_CHARS = 320;

type Header = { id?: string; cwd?: string; timestamp?: string };

/** First line of a session file, which records its cwd and id. */
function header(file: string): Header | undefined {
  let fd: number | undefined;
  try {
    fd = openSync(file, "r");
    const buffer = Buffer.alloc(8192);
    const read = readSync(fd, buffer, 0, buffer.length, 0);
    const newline = buffer.subarray(0, read).indexOf(0x0a);
    const parsed = JSON.parse(
      buffer.subarray(0, newline === -1 ? read : newline).toString("utf8"),
    ) as Header & {
      type?: string;
    };
    return parsed.type === "session" ? parsed : undefined;
  } catch {
    return undefined;
  } finally {
    if (fd !== undefined) closeSync(fd);
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

/** Every session file under the agent dir, excluding subagent task transcripts. */
function sessionFiles(includeSubagents: boolean): string[] {
  const root = join(getAgentDir(), "sessions");
  const out: string[] = [];
  const walk = (dir: string, depth: number) => {
    let names: string[];
    try {
      names = readdirSync(dir);
    } catch {
      return;
    }
    for (const name of names) {
      const path = join(dir, name);
      if (name.endsWith(".jsonl")) {
        if (includeSubagents || !dir.endsWith(`${join("", "tasks")}`)) out.push(path);
        continue;
      }
      if (depth > 0 && !includeSubagents) continue;
      let stat;
      try {
        stat = statSync(path);
      } catch {
        continue;
      }
      if (stat.isDirectory()) walk(path, depth + 1);
    }
  };
  walk(root, 0);
  return out.sort();
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
function entryText(
  entry: unknown,
  includeToolResults: boolean,
): { role: string; text: string; timestamp: string } | undefined {
  const row = entry as {
    type?: string;
    timestamp?: string;
    message?: { role?: string; content?: unknown };
  };
  if (row?.type !== "message" || !row.message) return undefined;
  const role = row.message.role ?? "";
  const wanted =
    role === "user" || role === "assistant" || (includeToolResults && role === "toolResult");
  if (!wanted) return undefined;
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
  includeToolResults?: boolean;
  since?: string;
  limit?: number;
  cwd: string;
  currentSessionFile?: string;
};

/** Ranked transcript excerpts matching `query`. */
export function searchSessions(query: SessionQuery): {
  hits: SessionHit[];
  scanned: number;
  skipped: number;
} {
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
  const since = query.since ? Date.parse(query.since) : undefined;
  const files = sessionFiles(query.includeSubagents ?? false).filter(
    (file) => file !== query.currentSessionFile,
  );
  const hits: SessionHit[] = [];
  const seen = new Set<string>();
  let scanned = 0;
  let skipped = 0;

  for (const file of files) {
    if (scanned >= MAX_FILES) {
      skipped = files.length - scanned;
      break;
    }
    const head = header(file);
    if (!head?.cwd) continue;
    if ((query.scope ?? "repo") === "repo" && !within(head.cwd, family)) continue;
    let raw: string;
    try {
      if (statSync(file).size > MAX_FILE_BYTES) {
        skipped++;
        continue;
      }
      raw = readFileSync(file, "utf8");
    } catch {
      skipped++;
      continue;
    }
    scanned++;
    const lower = raw.toLowerCase();
    if (!terms.some((term) => lower.includes(term))) continue;

    for (const rawLine of raw.split("\n")) {
      if (rawLine.length > MAX_LINE_BYTES || !rawLine.startsWith("{")) continue;
      const lowered = rawLine.toLowerCase();
      if (!terms.some((term) => lowered.includes(term))) continue;
      let entry: unknown;
      try {
        entry = JSON.parse(rawLine);
      } catch {
        continue;
      }
      const line = entryText(entry, query.includeToolResults ?? false);
      if (!line) continue;
      if (since !== undefined) {
        const at = Date.parse(line.timestamp);
        if (Number.isNaN(at) || at < since) continue;
      }
      const flat = line.text.replace(/\s+/g, " ").toLowerCase();
      const matched = terms.filter((term) => flat.includes(term));
      if (matched.length === 0) continue;
      const snippet = excerpt(line.text, matched[0]);
      const key = snippet.slice(0, 120);
      if (seen.has(key)) continue;
      seen.add(key);
      hits.push({
        session: head.id ?? basename(file, ".jsonl"),
        cwd: head.cwd,
        timestamp: line.timestamp,
        role: line.role,
        excerpt: snippet,
        file,
        score: matched.length + (flat.includes(query.query.toLowerCase()) ? 1 : 0),
      });
    }
  }
  hits.sort((a, b) => b.score - a.score || b.timestamp.localeCompare(a.timestamp));
  return { hits: hits.slice(0, query.limit ?? 5), scanned, skipped };
}
