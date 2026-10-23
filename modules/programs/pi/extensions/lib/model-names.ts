/**
 * How a model is named wherever pi shows one: the catalogue name with the
 * best-known lab names shortened, and a short tag for its provider. Shared by
 * the footer (chrome/footer.ts) and /models (model-labels.ts) so the two cannot
 * drift, and so `/models` says the same thing the footer will once selected.
 */
import type { Model } from "@earendil-works/pi-ai";

/**
 * Long, well-known lab names only; Qwen, GLM, Kimi, Nemotron and LongCat keep
 * their catalog names. Claude is redundant next to the provider tag.
 */
const ALIAS_PATTERNS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\bDeepSeek\b/gi, "DS"],
  [/\bMiniMax\b/gi, "MM"],
  [/\bClaude\s+/gi, ""],
];

/**
 * Short provider tags, two characters each so the column lines up in /models;
 * unknown providers keep their full id.
 */
export const PROVIDER_TAGS: Record<string, string> = {
  "opencode-go": "go",
  synthetic: "sy",
  tensorx: "tx",
  anthropic: "an",
  local: "sh",
};

/** The name plus tag, e.g. `DS V4.1 Flash` and `go`. */
export const modelName = (model: Model<any>): string => (model.name || model.id).trim();
export const modelTag = (provider: string): string => PROVIDER_TAGS[provider] ?? provider;

/** The name collapsed for a narrow line; the footer's second tier. */
export const modelAlias = (model: Model<any>): string => {
  let alias = modelName(model);
  for (const [pattern, replacement] of ALIAS_PATTERNS) {
    alias = alias.replace(pattern, replacement);
  }
  return alias.replace(/\s+/g, " ").trim() || modelName(model);
};
