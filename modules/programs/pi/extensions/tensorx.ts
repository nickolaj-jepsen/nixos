/**
 * TensorX provider whose model list comes from its `/v1/model/info` catalog
 * (limits, capabilities, prices), so new models show up in `/model` without
 * a config change. Per-model quirks the catalog can't express live in
 * MODELS below.
 *
 * Startup uses the last fetched catalog from a cache file, since pi selects
 * the default model before its own catalog refresh runs; only the first run
 * fetches synchronously. pi's refresh (startup, `/model`) rewrites the cache.
 * The cache holds the raw catalog, so edits to MODELS apply on the next start.
 */
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import {
  type ExtensionAPI,
  getAgentDir,
  type ProviderModelConfig,
} from "@earendil-works/pi-coding-agent";

type ChatModel = Extract<ProviderModelConfig, { reasoning: boolean }>;

const BASE_URL = "https://api.tensorx.ai/v1";
const FETCH_TIMEOUT_MS = 10_000;
// TensorX publishes no cache lifetime; 300s is the conservative default that lets pi warm it.
const PROMPT_CACHE_SECONDS = 300;

// LiteLLM's model_info; absent and null fields are both possible.
interface ModelInfo {
  model_name: string;
  model_info: {
    mode?: string | null;
    max_input_tokens?: number | null;
    max_output_tokens?: number | null;
    supports_reasoning?: boolean | null;
    supports_vision?: boolean | null;
    supports_prompt_caching?: boolean | null;
    input_cost_per_token?: number | null;
    output_cost_per_token?: number | null;
    cache_read_input_token_cost?: number | null;
  };
}

// Verified against TensorX for every model; per-model differences go in MODELS.
const COMPAT = {
  supportsStore: false,
  supportsDeveloperRole: false,
  supportsReasoningEffort: true,
  maxTokensField: "max_tokens",
  supportsStrictMode: false,
  thinkingFormat: "openai",
  sendSessionAffinityHeaders: true,
} as const;

// K3 and GLM 5.x always reason; only low/high/max are real levels.
const LOW_HIGH_MAX: ChatModel["thinkingLevelMap"] = {
  off: null,
  minimal: null,
  low: "low",
  medium: null,
  high: "high",
  xhigh: null,
  max: "max",
};

// Qwen 3.8's own levels: `high` is a 400, and thinking can't be turned off.
const QWEN_3_8: ChatModel["thinkingLevelMap"] = {
  off: null,
  minimal: null,
  low: "low",
  medium: "medium",
  high: null,
  xhigh: "xhigh",
  max: null,
};

const DEEPSEEK: Pick<ChatModel, "compat" | "thinkingLevelMap"> = {
  // DeepSeek rejects replayed turns missing reasoning_content.
  compat: {
    requiresReasoningContentOnAssistantMessages: true,
    thinkingFormat: "deepseek",
    supportsLongCacheRetention: true,
  },
  // `off` stays unset, not null, or it's dropped from the picker.
  thinkingLevelMap: { minimal: null, low: null, medium: null, high: "high", max: "max" },
};

type Price = Pick<ChatModel["cost"], "input" | "cacheRead" | "output">;

/**
 * Per-model settings. `price` is the tensorx.ai/models list price ($/1M,
 * 2026-10-14), used only when the catalog omits prices, so it can't mask a
 * price change.
 */
const MODELS: Record<string, Pick<ChatModel, "compat" | "thinkingLevelMap"> & { price?: Price }> = {
  "qwen/qwen3.8-2.4t-a95b": {
    thinkingLevelMap: QWEN_3_8,
    price: { input: 2.5, cacheRead: 0.63, output: 6 },
  },
  // 5.3 dropped `thinking.type: "disabled"`.
  "z-ai/glm-5.3": {
    thinkingLevelMap: LOW_HIGH_MAX,
    price: { input: 1.75, cacheRead: 0.44, output: 4.5 },
  },
  "moonshotai/kimi-k3": {
    thinkingLevelMap: LOW_HIGH_MAX,
    price: { input: 3, cacheRead: 0.75, output: 15 },
  },
  "z-ai/glm-5.3-flash": {
    thinkingLevelMap: LOW_HIGH_MAX,
    price: { input: 0.2, cacheRead: 0.05, output: 0.5 },
  },
  "qwen/qwen3.8-flash-next": {
    thinkingLevelMap: QWEN_3_8,
    price: { input: 0.2, cacheRead: 0.05, output: 0.5 },
  },
  "deepseek/deepseek-v4.1-flash": {
    ...DEEPSEEK,
    price: { input: 0.5, cacheRead: 0.13, output: 1.5 },
  },
  "deepseek/deepseek-v4-pro-0813": { ...DEEPSEEK, price: { input: 2, cacheRead: 0.5, output: 4 } },
  "deepseek/deepseek-v4-flash-0731": {
    ...DEEPSEEK,
    price: { input: 0.25, cacheRead: 0.06, output: 0.3 },
  },
  "z-ai/glm-5.2": { price: { input: 1.5, cacheRead: 0.38, output: 4.5 } },
  "qwen/qwen3.8-27b": {
    thinkingLevelMap: QWEN_3_8,
    price: { input: 0.4, cacheRead: 0.1, output: 2.4 },
  },
  "minimax/minimax-m3": { price: { input: 0.4, cacheRead: 0.1, output: 2 } },
  "moonshotai/kimi-k2.7-code": { price: { input: 1.25, cacheRead: 0.31, output: 4.5 } },
};

const perMillion = (perToken: number | null | undefined) =>
  Number(((perToken ?? 0) * 1e6).toPrecision(6));

function price(info: ModelInfo["model_info"], fallback: Price | undefined): ChatModel["cost"] {
  if (fallback && info.input_cost_per_token == null && info.output_cost_per_token == null) {
    return { ...fallback, cacheWrite: 0 };
  }
  return {
    input: perMillion(info.input_cost_per_token),
    output: perMillion(info.output_cost_per_token),
    cacheRead: perMillion(info.cache_read_input_token_cost),
    cacheWrite: 0,
  };
}

/** Chat models from a `/v1/model/info` payload, deduplicated by id (one entry per deployment). */
function toModels(data: ModelInfo[]): ChatModel[] {
  const byId = new Map<string, ChatModel>();
  for (const { model_name: id, model_info: info } of data) {
    // pi needs a context window; a catalog entry without one isn't usable.
    const contextWindow = info.max_input_tokens;
    if (info.mode !== "chat" || !contextWindow || byId.has(id)) continue;
    const { price: listPrice, compat, thinkingLevelMap } = MODELS[id] ?? {};
    byId.set(id, {
      id,
      name: id,
      reasoning: info.supports_reasoning ?? false,
      input: info.supports_vision ? ["text", "image"] : ["text"],
      contextWindow,
      maxTokens: info.max_output_tokens ?? contextWindow,
      cost: price(info, listPrice),
      ...(info.supports_prompt_caching ? { promptCache: { short: PROMPT_CACHE_SECONDS } } : {}),
      compat: { ...COMPAT, ...compat },
      ...(thinkingLevelMap ? { thinkingLevelMap } : {}),
    });
  }
  return [...byId.values()];
}

async function fetchCatalog(apiKey: string, signal?: AbortSignal): Promise<ModelInfo[]> {
  const timeout = AbortSignal.timeout(FETCH_TIMEOUT_MS);
  const res = await fetch(`${BASE_URL}/model/info`, {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
  });
  if (!res.ok) throw new Error(`TensorX /model/info: HTTP ${res.status}`);
  const { data } = (await res.json()) as { data: ModelInfo[] };
  if (toModels(data).length === 0) throw new Error("TensorX /model/info returned no chat models");
  return data;
}

function readKey(path: string): string | undefined {
  try {
    return readFileSync(path, "utf8").trim() || undefined;
  } catch {
    return undefined;
  }
}

function readCache(path: string): ModelInfo[] | undefined {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as ModelInfo[];
  } catch {
    return undefined;
  }
}

function writeCache(path: string, catalog: ModelInfo[]) {
  mkdirSync(dirname(path), { recursive: true });
  // Atomic, as parallel pi processes refresh concurrently.
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(catalog));
  renameSync(tmp, path);
}

export default async function (pi: ExtensionAPI) {
  // agenix links the secret here; hosts without it get no TensorX provider.
  const apiKey = readKey(join(getAgentDir(), "tensorx-api-key"));
  if (!apiKey) return;

  const cachePath = join(getAgentDir(), "tensorx-catalog.json");
  let catalog = readCache(cachePath) ?? [];
  if (catalog.length === 0) {
    try {
      catalog = await fetchCatalog(apiKey);
      writeCache(cachePath, catalog);
    } catch {
      // Offline on first run: start empty and let pi's refresh fill it in.
    }
  }

  pi.registerProvider("tensorx", {
    name: "TensorX",
    baseUrl: BASE_URL,
    api: "openai-completions",
    apiKey,
    models: toModels(catalog),
    refreshModels: async (context) => {
      if (context.allowNetwork) {
        catalog = await fetchCatalog(apiKey, context.signal);
        writeCache(cachePath, catalog);
      }
      return toModels(catalog);
    },
  });
}
