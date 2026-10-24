/**
 * How a model is named wherever pi shows one: the catalogue name with the
 * best-known lab names shortened, and the provider as a person reads it. Shared
 * by the footer (chrome/footer.ts) and /models (model-labels.ts) so the two
 * cannot drift, and so `/models` says the same thing the footer will once
 * selected.
 */
import type { Model } from "@earendil-works/pi-ai";

/**
 * Long, well-known lab names only; Qwen, GLM, Kimi, Nemotron and LongCat keep
 * their catalog names. Claude is redundant next to the spelled-out provider.
 */
const ALIAS_PATTERNS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\bDeepSeek\b/gi, "DS"],
  [/\bMiniMax\b/gi, "MM"],
  [/\bClaude\s+/gi, ""],
];

/** Providers whose catalogue name is not what a person reads. */
const PROVIDER_NAMES: Record<string, string> = { vm: "Virtual" };

/** What a model's provider is called: the catalogue name, or the id when pi has none. */
type DisplayNames = { getProviderDisplayName(provider: string): string };

/** The name as the catalogue spells it, e.g. `DeepSeek V4.1 Flash`. */
export const modelName = (model: Model<any>): string => (model.name || model.id).trim();

/** The provider as a person reads it, e.g. `OpenCode Go` and `Virtual`. */
export const providerName = (provider: string, registry: DisplayNames): string =>
  PROVIDER_NAMES[provider] ?? registry.getProviderDisplayName(provider);

/** The provider squeezed for a narrow line: `OpenCode Go` collapses to its last word. */
export const providerShortName = (name: string): string =>
  name.slice(name.lastIndexOf(" ") + 1) || name;

/** The name collapsed for a narrow line; the footer's second tier. */
export const modelAlias = (model: Model<any>): string => {
  let alias = modelName(model);
  for (const [pattern, replacement] of ALIAS_PATTERNS) {
    alias = alias.replace(pattern, replacement);
  }
  return alias.replace(/\s+/g, " ").trim() || modelName(model);
};
