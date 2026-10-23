/**
 * Why the session cost what it did: replies that paid to rebuild the prompt
 * cache, how much of the output was reasoning, and what the context re-sent on
 * every request was made of. Token counts of context content are estimates
 * (characters / 4); the money is always the replies' own, only its split is.
 */
import type { AssistantMessage, Usage } from "@earendil-works/pi-ai";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import type { Price } from "./breakdown.ts";

/** What pi's catalog says about a model; any part may be unknown. */
export type Catalog = (
  provider: string,
  model: string,
) => { price?: Price; cacheTtl?: { short?: number; long?: number } } | undefined;

/* ----------------------------------------------------------- cache rebuilds */

export type RebuildCause = "idle" | "model switch" | "prefix changed";

export type Rebuild = {
  entryId: string;
  cause: RebuildCause;
  /** Seconds between the previous reply ending and this request starting. */
  gap: number;
  /** Prompt tokens the previous reply had cached that this one paid to send again. */
  tokens: number;
  /** What those tokens cost over reading them from the cache. */
  usd: number;
};

// A smaller miss is noise: the newest tool results are always uncached.
const MIN_REBUILD_TOKENS = 2048;
const MIN_REBUILD_SHARE = 0.5;
// Lifetimes when the catalog names none: the common 5-minute tier, and Anthropic's 1h one.
const DEFAULT_TTL_S = 300;
const DEFAULT_LONG_TTL_S = 3600;

const promptTokens = (u: Usage) => u.input + u.cacheRead + u.cacheWrite;

/**
 * The reply each reply followed, by entry id; null after a compaction or at the
 * start, where nothing could be cached. Walks parents rather than file order, so
 * a reply on one branch is never compared with a reply on another.
 */
const previousReplies = (entries: readonly SessionEntry[]) => {
  const byId = new Map(entries.map((e) => [e.id, e]));
  const before = new Map<string, AssistantMessage | null>();
  for (const entry of entries) {
    const parent = entry.parentId ? byId.get(entry.parentId) : undefined;
    let previous: AssistantMessage | null = null;
    if (parent?.type === "message" && parent.message.role === "assistant")
      previous = parent.message;
    else if (parent && parent.type !== "compaction") previous = before.get(parent.id) ?? null;
    before.set(entry.id, previous);
  }
  return before;
};

/**
 * Replies that sent most of the previous reply's context again at full price
 * instead of reading it from the cache. A cold start or the first reply after a
 * compaction has nothing to read and is not one.
 */
export const cacheRebuilds = (entries: readonly SessionEntry[], catalog: Catalog): Rebuild[] => {
  const before = previousReplies(entries);
  const rebuilds: Rebuild[] = [];
  for (const entry of entries) {
    if (entry.type !== "message" || entry.message.role !== "assistant") continue;
    const reply = entry.message;
    const previous = before.get(entry.id);
    if (!previous) continue;
    const u = reply.usage;
    const prior = promptTokens(previous.usage) + previous.usage.output;
    const expected = Math.min(prior, promptTokens(u));
    const missed = expected - u.cacheRead;
    if (missed < MIN_REBUILD_TOKENS || missed < expected * MIN_REBUILD_SHARE) continue;

    const info = catalog(reply.provider, reply.model);
    const ended = previous.timestamp + (previous.durationMs ?? 0);
    const gap = Math.max(0, (reply.timestamp - ended) / 1000);
    const prevInfo = catalog(previous.provider, previous.model);
    const ttl =
      (previous.usage.cacheWrite1h ?? 0) > 0
        ? (prevInfo?.cacheTtl?.long ?? DEFAULT_LONG_TTL_S)
        : (prevInfo?.cacheTtl?.short ?? DEFAULT_TTL_S);
    const cause: RebuildCause =
      previous.provider !== reply.provider || previous.model !== reply.model
        ? "model switch"
        : gap > ttl
          ? "idle"
          : "prefix changed";

    // The missed tokens went in as cache writes where the provider writes, as input otherwise.
    const writeRate = u.cacheWrite > 0 ? u.cost.cacheWrite / u.cacheWrite : undefined;
    const inputRate = u.input > 0 ? u.cost.input / u.input : (info?.price?.input ?? 0) / 1e6;
    const readRate =
      info?.price !== undefined
        ? info.price.cacheRead / 1e6
        : u.cacheRead > 0
          ? u.cost.cacheRead / u.cacheRead
          : 0;
    const usd = missed * Math.max(0, (writeRate ?? inputRate) - readRate);
    rebuilds.push({ entryId: entry.id, cause, gap, tokens: missed, usd });
  }
  return rebuilds;
};

/* ----------------------------------------------------------------- thinking */

export type ThinkingLevelView = {
  level: string;
  replies: number;
  output: number;
  /** Undefined when no reply at this level reported a reasoning count. */
  reasoning?: number;
  reasoningUsd: number;
  outputUsd: number;
};

/** Output and reasoning per thinking level, over every reply that reported a level. */
export const thinkingByLevel = (entries: readonly SessionEntry[]): ThinkingLevelView[] => {
  const levels = new Map<string, ThinkingLevelView>();
  for (const entry of entries) {
    if (entry.type !== "message" || entry.message.role !== "assistant") continue;
    const { usage: u, thinkingLevel } = entry.message;
    if (u.output <= 0) continue;
    const level = thinkingLevel ?? "unknown";
    const view = levels.get(level) ?? {
      level,
      replies: 0,
      output: 0,
      reasoningUsd: 0,
      outputUsd: 0,
    };
    view.replies += 1;
    view.output += u.output;
    view.outputUsd += u.cost.output;
    if (u.reasoning !== undefined) {
      view.reasoning = (view.reasoning ?? 0) + u.reasoning;
      // Reasoning is billed as output.
      view.reasoningUsd += u.reasoning * (u.cost.output / u.output);
    }
    levels.set(level, view);
  }
  return [...levels.values()].sort((a, b) => b.outputUsd - a.outputUsd);
};

/* ---------------------------------------------------------- context drivers */

export type ContextSource = {
  name: string;
  /** Estimated tokens of it in the context now. */
  now: number;
  /** Its share of every request's prompt cost on this branch. */
  usd: number;
};

export const SYSTEM_SOURCE = "system & tools";
const PROMPTS_SOURCE = "your prompts";
const REPLIES_SOURCE = "replies";
const SUMMARY_SOURCE = "summaries";
// A conservative token count for an image, which has no text to measure.
const IMAGE_TOKENS = 1200;

const estimate = (content: unknown): number => {
  if (typeof content === "string") return Math.ceil(content.length / 4);
  if (!Array.isArray(content)) return 0;
  let tokens = 0;
  for (const block of content) {
    if (block?.type === "text" && typeof block.text === "string") tokens += block.text.length / 4;
    else if (block?.type === "image") tokens += IMAGE_TOKENS;
    else if (block?.type === "toolCall") tokens += JSON.stringify(block.arguments ?? {}).length / 4;
  }
  return Math.ceil(tokens);
};

type Piece = { id: string; source: string; tokens: number };

/**
 * Walks the branch keeping the context as pieces, and calls `onReply` with it
 * before each reply. A compaction leaves its summary plus the entries from its
 * first kept one on, as pi builds the context.
 */
const walkContext = (
  branch: readonly SessionEntry[],
  onReply: (pieces: readonly Piece[], usage: Usage) => void,
): Piece[] => {
  let pieces: Piece[] = [];
  for (const entry of branch) {
    if (entry.type === "compaction") {
      const kept = pieces.findIndex((p) => p.id === entry.firstKeptEntryId);
      pieces = kept >= 0 ? pieces.slice(kept) : [];
      pieces.push({ id: entry.id, source: SUMMARY_SOURCE, tokens: estimate(entry.summary) });
      continue;
    }
    if (entry.type === "branch_summary") {
      pieces.push({ id: entry.id, source: SUMMARY_SOURCE, tokens: estimate(entry.summary) });
      continue;
    }
    if (entry.type !== "message") continue;
    const message = entry.message;
    if (message.role === "user") {
      pieces.push({ id: entry.id, source: PROMPTS_SOURCE, tokens: estimate(message.content) });
    } else if (message.role === "toolResult") {
      pieces.push({ id: entry.id, source: message.toolName, tokens: estimate(message.content) });
    } else if (message.role === "assistant") {
      if (promptTokens(message.usage) > 0) onReply(pieces, message.usage);
      // Its text and tool calls are in every later request; earlier thinking is dropped.
      const sent = message.content.filter((block) => block.type !== "thinking");
      pieces.push({ id: entry.id, source: REPLIES_SOURCE, tokens: estimate(sent) });
    }
  }
  return pieces;
};

const bySource = (pieces: readonly Piece[]) => {
  const sums = new Map<string, number>();
  for (const p of pieces) sums.set(p.source, (sums.get(p.source) ?? 0) + p.tokens);
  return sums;
};

/**
 * What the requests on the current branch re-sent, by source. Each reply's
 * actual prompt cost is split over what it was sent with. The system prompt and
 * tool declarations are the smallest part of any prompt the content estimate
 * cannot explain; the rest of the prompt is shared over the content by its
 * estimated size, which calibrates the estimate against the real count.
 */
export const contextDrivers = (
  branch: readonly SessionEntry[],
  contextTokens: number | undefined,
): ContextSource[] => {
  const sum = (pieces: readonly Piece[]) => pieces.reduce((a, p) => a + p.tokens, 0);
  let system = Number.POSITIVE_INFINITY;
  let lastPrompt = 0;
  walkContext(branch, (pieces, usage) => {
    system = Math.min(system, Math.max(0, promptTokens(usage) - sum(pieces)));
  });
  if (!Number.isFinite(system)) system = 0;

  const spent = new Map<string, number>();
  const add = (key: string, usd: number) => spent.set(key, (spent.get(key) ?? 0) + usd);
  const live = walkContext(branch, (pieces, usage) => {
    const prompt = promptTokens(usage);
    const usd = usage.cost.input + usage.cost.cacheRead + usage.cost.cacheWrite;
    const sys = Math.min(system, prompt);
    add(SYSTEM_SOURCE, (usd * sys) / prompt);
    const known = sum(pieces);
    if (known > 0) {
      for (const [source, tokens] of bySource(pieces)) {
        add(source, (usd * ((prompt - sys) / prompt) * tokens) / known);
      }
    }
    lastPrompt = prompt;
  });

  const total = contextTokens ?? lastPrompt;
  const known = sum(live);
  const content = Math.max(0, total - system);
  const now = new Map<string, number>([[SYSTEM_SOURCE, Math.min(system, total)]]);
  for (const [source, tokens] of bySource(live)) {
    now.set(source, known > 0 ? (content * tokens) / known : 0);
  }
  return [...new Set([...now.keys(), ...spent.keys()])]
    .map((name) => ({ name, now: Math.round(now.get(name) ?? 0), usd: spent.get(name) ?? 0 }))
    .filter((s) => s.usd > 0.00005 || s.now > 0)
    .sort((a, b) => b.usd - a.usd);
};
