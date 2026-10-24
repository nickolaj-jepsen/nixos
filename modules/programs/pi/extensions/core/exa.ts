/**
 * Exa search and page fetch. Search returns highlights by default, which Exa
 * sizes for relevance; fetch returns page text. Both cap the whole call to a
 * share of the active model's context and split that share across results or
 * pages, so the tools stay usable on small windows. `maxChars` changes the
 * per-item cap, but the call total still wins.
 */
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionToolContext } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { usdUsage } from "../shared/usage-ledger.ts";

const API = "https://api.exa.ai";
// A call may spend at most this share of the window or of the free context.
const WINDOW_SHARE = 0.06;
const FREE_SHARE = 0.25;
const MIN_TOTAL_CHARS = 4_000;
const MAX_TOTAL_CHARS = 120_000;
const DEFAULT_SEARCH_CHARS = 8_000;
const MAX_PAGE_CHARS = 30_000;
const MIN_PAGE_CHARS = 1_500;

// Exa's fee as tool-result usage, which pi counts in the session total even under codemode.
const fee = (costUsd: number | undefined) =>
  costUsd !== undefined && costUsd > 0 ? { usage: usdUsage(costUsd) } : {};

type Mode = "highlights" | "text" | "summary";

interface ExaResult {
  title?: string;
  url?: string;
  publishedDate?: string;
  text?: string;
  summary?: string;
  highlights?: string[];
}

interface ExaStatus {
  id: string;
  status: string;
}

interface ExaResponse {
  results?: ExaResult[];
  statuses?: ExaStatus[];
  costDollars?: { total?: number };
}

/** Total chars one call may add to the context, and the window used for result counts. */
function contextBudget(ctx: ExtensionToolContext) {
  const usage = ctx.getContextUsage();
  const window = usage?.contextWindow ?? ctx.model?.contextWindow ?? 200_000;
  const free = usage?.tokens == null ? window / 2 : Math.max(0, window - usage.tokens);
  const share = Math.min(window * WINDOW_SHARE, free * FREE_SHARE) * 4;
  return {
    window,
    total: Math.min(MAX_TOTAL_CHARS, Math.max(MIN_TOTAL_CHARS, Math.floor(share))),
  };
}

const resultCount = (window: number) =>
  window >= 500_000 ? 10 : window >= 150_000 ? 8 : window >= 64_000 ? 5 : 3;

let apiKey: string | undefined;

/** The key from `$PI_EXA_KEY_FILE`, read on first use and cached; throws when unset, unreadable or empty. */
function exaKey(): string {
  if (apiKey) return apiKey;
  const file = process.env.PI_EXA_KEY_FILE;
  // Points at the agenix secret, so say what is missing rather than how to curl it.
  if (!file) throw new Error("PI_EXA_KEY_FILE is unset (secret: exa-api-key).");
  let key: string;
  try {
    key = readFileSync(file, "utf8").trim();
  } catch (err) {
    throw new Error(`Can't read the Exa key (secret: exa-api-key): ${(err as Error).message}`);
  }
  if (!key) throw new Error(`The Exa key file ${file} is empty (secret: exa-api-key).`);
  return (apiKey = key);
}

async function post<T extends ExaResponse>(
  path: string,
  body: unknown,
  signal?: AbortSignal,
): Promise<T> {
  const res = await fetch(`${API}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": exaKey() },
    body: JSON.stringify(body),
    signal,
  });
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 300);
    throw new Error(`Exa ${path} HTTP ${res.status}: ${detail}`);
  }
  return (await res.json()) as T;
}

/** `contents` for one mode. `cap` is the share of the call budget for this item. */
function contents(mode: Mode, cap: number, query: string) {
  if (mode === "text") return { text: { maxCharacters: cap } };
  if (mode === "summary") return { summary: { query } };
  return { highlights: { maxCharacters: cap } };
}

const excerpt = (r: ExaResult) => {
  const highlights = r.highlights?.join("\n…\n").trim();
  return highlights || r.text || r.summary || "";
};

/** One block per result: rank, title, bare URL for copying, then the evidence. */
function format(results: ExaResult[], numbered: boolean) {
  return results
    .map((r, i) => {
      const head = [numbered ? `[${i + 1}]` : "", r.title ?? ""].filter(Boolean).join(" ");
      const date = r.publishedDate ? ` (${r.publishedDate.slice(0, 10)})` : "";
      return `${head}${date}\n${r.url ?? ""}\n${excerpt(r)}`;
    })
    .join("\n\n");
}

function truncatedUrl(r: ExaResult, mode: Mode, cap: number): string | undefined {
  const cut =
    mode === "text"
      ? (r.text?.length ?? 0) >= cap
      : mode === "highlights"
        ? (r.highlights?.join("").length ?? 0) >= cap
        : false;
  return cut ? r.url : undefined;
}

function shortList(items: string[]): string {
  return items.length <= 4
    ? items.join(", ")
    : `${items.slice(0, 3).join(", ")} and ${items.length - 3} more`;
}

const footer = (notes: string[]) => (notes.length > 0 ? `\n\n[${notes.join("; ")}]` : "");

const modeParam = (fallback: Mode, detail: string) =>
  Type.Optional(
    Type.Union([Type.Literal("highlights"), Type.Literal("text"), Type.Literal("summary")], {
      description: `${detail} Defaults to "${fallback}".`,
    }),
  );

const capParam = (detail: string) =>
  Type.Optional(Type.Number({ minimum: 1, description: detail }));

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "exa_search",
    label: "Exa search",
    description:
      "Search the web through Exa and get back the passages that answer the query. Use it for anything outside the repo: current docs, APIs, releases, error messages, news.",
    promptSnippet:
      "Web search returning query-relevant excerpts per result; exa_fetch reads URLs you already have.",
    parameters: Type.Object({
      query: Type.String({
        description: "Natural-language query. Describe the page you want, not keywords.",
      }),
      objective: Type.String({
        description:
          "Goal for this search turn; say which documents should rank first, which should be excluded, and what specific facts or figures to pull from them.",
      }),
      mode: modeParam(
        "highlights",
        'Per result: "highlights" (excerpts chosen for the query), "text" (page body), "summary" (LLM digest).',
      ),
      numResults: Type.Optional(
        Type.Number({
          minimum: 1,
          maximum: 100,
          description:
            "Defaults to 3/5/8/10 by context window. More results means shorter excerpts under the call budget.",
        }),
      ),
      maxChars: capParam(
        "Per-result character budget. Defaults to a share of the call budget; lower numResults for longer excerpts.",
      ),
      includeDomains: Type.Optional(
        Type.Array(Type.String(), { description: "Only search these domains." }),
      ),
      startPublishedDate: Type.Optional(
        Type.String({ description: "ISO date; drops anything published earlier." }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const { window, total } = contextBudget(ctx);
      const mode = params.mode ?? "highlights";
      const numResults = params.numResults ?? resultCount(window);
      const cap = Math.max(
        1,
        Math.min(params.maxChars ?? DEFAULT_SEARCH_CHARS, Math.floor(total / numResults)),
      );
      const data = await post<ExaResponse>(
        "/search",
        {
          query: params.query,
          numResults,
          objective: params.objective,
          includeDomains: params.includeDomains,
          startPublishedDate: params.startPublishedDate,
          contents: contents(mode, cap, params.objective),
        },
        signal,
      );

      const results = data.results ?? [];
      const costUsd = data.costDollars?.total;
      const truncated = results
        .map((r) => truncatedUrl(r, mode, cap))
        .filter((url): url is string => Boolean(url));

      if (results.length === 0) {
        return {
          content: [{ type: "text" as const, text: `No results for "${params.query}".` }],
          details: { numResults, mode, costUsd, truncated: [] },
          ...fee(costUsd),
        };
      }
      const notes =
        truncated.length > 0 ? [`Capped at ~${cap} chars: ${shortList(truncated)}`] : [];
      return {
        content: [{ type: "text" as const, text: format(results, true) + footer(notes) }],
        details: { numResults, mode, costUsd, truncated },
        ...fee(costUsd),
      };
    },
  });

  pi.registerTool({
    name: "exa_fetch",
    label: "Exa fetch",
    description:
      "Read pages you already have URLs for: Exa extracts the body, so it works on docs, READMEs and articles that curl turns into script tags.",
    promptSnippet:
      "Extract page content for known URLs; prefer it over curl for rendered or JS-heavy pages.",
    parameters: Type.Object({
      urls: Type.Array(Type.String(), {
        minItems: 1,
        maxItems: 100,
        description: "Pages to read; the context budget may skip some.",
      }),
      mode: modeParam(
        "text",
        'Per page: "text" (page body), "highlights" (short excerpts), "summary" (LLM digest).',
      ),
      maxChars: capParam(
        "Per-page character budget. Defaults to a share of the call budget; summary ignores it.",
      ),
      maxAgeHours: Type.Optional(
        Type.Integer({
          minimum: -1,
          maximum: 720,
          description:
            "Maximum age of cached content in hours: 0 always fetches fresh, -1 always uses cache, 1-720 tolerates cache that old. Defaults to 24.",
        }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const { total } = contextBudget(ctx);
      const mode = params.mode ?? "text";
      const pageCap = Math.max(1, Math.min(params.maxChars ?? MAX_PAGE_CHARS, MAX_PAGE_CHARS));
      const maxPages = Math.max(
        1,
        Math.min(params.urls.length, Math.floor(total / Math.min(pageCap, MIN_PAGE_CHARS))),
      );
      const perPage = Math.max(1, Math.min(pageCap, Math.floor(total / maxPages)));
      const urls = params.urls.slice(0, maxPages);
      const skipped = params.urls.slice(maxPages);

      const data = await post<ExaResponse>(
        "/contents",
        {
          urls,
          maxAgeHours: params.maxAgeHours ?? 24,
          ...contents(mode, perPage, urls.join(" ")),
        },
        signal,
      );

      const results = (data.results ?? []).filter((r) => r.url);
      const costUsd = data.costDollars?.total;
      const failed = (data.statuses ?? [])
        .filter((s) => s.status !== "success")
        .map((s) => `${s.id} (${s.status})`);
      const truncated = results
        .map((r) => truncatedUrl(r, mode, perPage))
        .filter((url): url is string => Boolean(url));
      const notes = [
        ...(truncated.length > 0 ? [`Capped at ~${perPage} chars: ${shortList(truncated)}`] : []),
        ...(skipped.length > 0 ? [`Skipped (context budget): ${shortList(skipped)}`] : []),
        ...(failed.length > 0 ? [`Failed: ${shortList(failed)}`] : []),
      ];

      if (results.length === 0) {
        return {
          content: [{ type: "text" as const, text: `Nothing extracted.${footer(notes)}` }],
          details: { mode, costUsd, truncated, skipped, failed },
          ...fee(costUsd),
        };
      }
      return {
        content: [{ type: "text" as const, text: format(results, false) + footer(notes) }],
        details: { mode, pages: results.length, costUsd, truncated, skipped, failed },
        ...fee(costUsd),
      };
    },
  });
}
