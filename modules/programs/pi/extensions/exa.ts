/**
 * Exa search and page fetch. Highlights are the default: Exa's extractor picks
 * the passages that answer the query on every request, so a per-result character
 * cap mostly trades quality for tokens that were never the problem. Result count
 * is the knob nothing server-side adapts, so it follows the active model's
 * context window and the space actually left in it.
 *
 * Both tools take explicit `numResults`/`maxChars` overrides so the model can
 * push past the sizing when recall is short, and neither is required to.
 */
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionToolContext } from "@earendil-works/pi-coding-agent";

const API = "https://api.exa.ai";
// Under this much free context, results compete with the reasoning about them.
const TIGHT_FREE_TOKENS = 60_000;
const TIGHT_USED_PERCENT = 60;

// Exa list prices per 1k requests, so the footer can count search spend alongside
// model spend. A plan other than pay-as-you-go makes these wrong.
const SEARCH_PER_1K = { auto: 7, lite: 4, deep: 12 } as const;
const EXTRA_RESULT_PER_1K = 1; // each result past the first 10
const PAGE_PER_1K = 1; // contents, per page per content type

interface ExaResult {
  title?: string;
  url?: string;
  publishedDate?: string;
  text?: string;
  summary?: string;
  highlights?: string[];
}

/** Result count and text budget for the model in play; only its window knows what fits. */
function budget(ctx: ExtensionToolContext) {
  const window = ctx.model?.contextWindow ?? 200_000;
  const usage = ctx.getContextUsage();
  // `tokens` is null right after compaction, before the next response reports.
  const free = usage?.tokens != null ? window - usage.tokens : window / 2;
  const tight = free < TIGHT_FREE_TOKENS || (usage?.percent ?? 0) > TIGHT_USED_PERCENT;

  if (tight) return { numResults: 3, maxChars: 1_500 };
  if (window >= 500_000) return { numResults: 10, maxChars: 8_000 };
  if (window >= 150_000) return { numResults: 8, maxChars: 5_000 };
  return { numResults: 5, maxChars: 2_500 };
}

async function post<T>(path: string, body: unknown, signal?: AbortSignal): Promise<T> {
  const key = process.env.EXA_API_KEY;
  // Points at the agenix secret, so say what is missing rather than how to curl it.
  if (!key) throw new Error("EXA_API_KEY is unset (secret: exa-api-key).");

  const res = await fetch(`${API}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": key },
    body: JSON.stringify(body),
    signal,
  });
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 300);
    throw new Error(`Exa ${path} HTTP ${res.status}: ${detail}`);
  }
  return (await res.json()) as T;
}

/** `contents` for one mode. A cap is only sent when it was asked for, or when text needs bounding. */
function contents(mode: "highlights" | "text" | "summary", cap: number | undefined, query: string) {
  if (mode === "text") return { text: { maxCharacters: cap ?? 5_000 } };
  if (mode === "summary") return { summary: { query } };
  return { highlights: cap === undefined ? (true as const) : { maxCharacters: cap } };
}

const excerpt = (r: ExaResult) => (r.highlights?.join("\n…\n") ?? r.text ?? r.summary ?? "").trim();

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

const modeParam = (fallback: string, detail: string) =>
  Type.Optional(
    Type.Union([Type.Literal("highlights"), Type.Literal("text"), Type.Literal("summary")], {
      description: `${detail} Defaults to "${fallback}".`,
    }),
  );

const capParam = (detail: string) =>
  Type.Optional(
    Type.Number({
      description: `${detail} Unset by default so Exa sizes highlights to relevance; setting it caps every result at that many characters.`,
    }),
  );

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "exa_search",
    label: "Exa search",
    description:
      "Search the web through Exa and get back the passages that answer the query. Use it for anything outside the repo: current docs, APIs, releases, error messages, news.",
    promptSnippet:
      "exa_search: web search returning query-relevant excerpts per result; exa_fetch reads URLs you already have.",
    parameters: Type.Object({
      query: Type.String({
        description: "Natural-language query. Describe the page you want, not keywords.",
      }),
      objective: Type.Optional(
        Type.String({
          description:
            "The goal this search serves. Exa selects excerpts against it, so pass the task rather than repeating the query.",
        }),
      ),
      mode: modeParam(
        "highlights",
        'Per result: "highlights" (excerpts chosen for the query), "text" (page body), "summary" (LLM digest).',
      ),
      numResults: Type.Optional(
        Type.Number({
          description:
            "Already sized to the active model's context window and free space, so leave it unset; set it when recall is too low or the answer is clearly not in these results.",
        }),
      ),
      maxChars: capParam("Per-result character budget."),
      type: Type.Optional(
        Type.Union([Type.Literal("auto"), Type.Literal("lite"), Type.Literal("deep")], {
          description:
            'Search mode. "auto" is the balanced default; "lite" skips live fetching for low latency; "deep" runs multi-step research and is much slower and pricier.',
        }),
      ),
      category: Type.Optional(
        Type.String({
          description:
            "Restrict to a data type, e.g. news, research paper, company, pdf, personal site, github.",
        }),
      ),
      includeDomains: Type.Optional(
        Type.Array(Type.String(), { description: "Only search these domains." }),
      ),
      excludeDomains: Type.Optional(
        Type.Array(Type.String(), { description: "Never search these domains." }),
      ),
      startPublishedDate: Type.Optional(
        Type.String({ description: "ISO date; drops anything published earlier." }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const limits = budget(ctx);
      const mode = params.mode ?? "highlights";
      const numResults = params.numResults ?? limits.numResults;
      const type = params.type ?? "auto";

      const data = await post<{ results?: ExaResult[] }>(
        "/search",
        {
          query: params.query,
          type,
          numResults,
          objective: params.objective,
          category: params.category,
          includeDomains: params.includeDomains,
          excludeDomains: params.excludeDomains,
          startPublishedDate: params.startPublishedDate,
          contents: contents(
            mode,
            params.maxChars ?? (mode === "highlights" ? undefined : limits.maxChars),
            params.objective ?? params.query,
          ),
        },
        signal,
      );

      const results = data.results ?? [];
      // Billed per request, whether or not anything came back.
      const costUsd =
        (SEARCH_PER_1K[type] + Math.max(0, numResults - 10) * EXTRA_RESULT_PER_1K) / 1000;
      if (results.length === 0) {
        return {
          content: [{ type: "text" as const, text: `No results for "${params.query}".` }],
          details: { numResults, mode, costUsd },
        };
      }
      return {
        content: [{ type: "text" as const, text: format(results, true) }],
        details: { numResults, mode, costUsd },
      };
    },
  });

  pi.registerTool({
    name: "exa_fetch",
    label: "Exa fetch",
    description:
      "Read pages you already have URLs for: Exa extracts the body, so it works on docs, READMEs and articles that curl turns into script tags.",
    promptSnippet:
      "exa_fetch: extract page content for known URLs; prefer it over curl for rendered or JS-heavy pages.",
    parameters: Type.Object({
      urls: Type.Array(Type.String(), { description: "Pages to read." }),
      mode: modeParam(
        "text",
        'Per page: "text" (full body up to the budget), "highlights" (short excerpts), "summary" (LLM digest).',
      ),
      maxChars: capParam("Per-page character budget."),
      livecrawl: Type.Optional(
        Type.Union(
          [
            Type.Literal("never"),
            Type.Literal("fallback"),
            Type.Literal("always"),
            Type.Literal("auto"),
            Type.Literal("preferred"),
          ],
          {
            description:
              'Cache policy. "never" is fastest and stalest; "fallback" refetches only when the cache is stale; use one of those two when a page changed recently.',
          },
        ),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const limits = budget(ctx);
      const mode = params.mode ?? "text";

      const data = await post<{
        results?: ExaResult[];
        statuses?: { id: string; status: string }[];
      }>(
        "/contents",
        {
          urls: params.urls,
          livecrawl: params.livecrawl,
          ...contents(mode, params.maxChars ?? limits.maxChars, params.urls.join(" ")),
        },
        signal,
      );

      const results = (data.results ?? []).filter((r) => r.url);
      // Pages Exa actually returned; a failed extraction is not billed.
      const costUsd = (results.length * PAGE_PER_1K) / 1000;
      if (results.length === 0) {
        const failed = data.statuses?.map((s) => `${s.id}: ${s.status}`).join(", ");
        return {
          content: [
            { type: "text" as const, text: `Nothing extracted${failed ? ` (${failed})` : ""}.` },
          ],
          details: { mode, costUsd },
        };
      }
      return {
        content: [{ type: "text" as const, text: format(results, false) }],
        details: { mode, pages: results.length, costUsd },
      };
    },
  });
}
