/**
 * The models `/model` lists, per provider: `registerProvider`'s `models`
 * replaces a provider's catalog instead of adding to it, so what is picked here
 * is all that provider offers. Metadata, prices and capabilities come from pi's
 * own catalog, so the lists below only name ids.
 *
 * Each provider shows its hand-picked ids plus (except for anthropic) its free
 * tier, so a zero-cost model that starts being billed drops out of pi's catalog
 * on the next refresh instead of sitting in the picker looking free.
 */
import { getBuiltinModels } from "@earendil-works/pi-ai/providers/all";
import type { ExtensionAPI, ProviderModelConfig } from "@earendil-works/pi-coding-agent";

type Chat = Extract<ProviderModelConfig, { reasoning: boolean }>;

// Providers whose built-in catalog this replaces. TensorX is a models.json
// provider (see _tensorx-models.nix), so it needs no filtering.
const OVERRIDES = ["anthropic", "opencode", "opencode-go"] as const;

export const CURATED: Record<(typeof OVERRIDES)[number], readonly string[]> = {
  anthropic: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
  // Nothing hand-picked: free models are the only Zen ones worth a picker entry.
  opencode: [],
  "opencode-go": ["deepseek-v4.1-flash", "glm-5.3", "qwen3.8-flash", "minimax-m3", "kimi-k3"],
};

// Free models not worth a picker entry, as `provider/id`. New free models show
// up without an edit; these do not.
const HIDDEN = new Set<string>();

const isFree = (model: Chat) => model.cost.input === 0 && model.cost.output === 0;

export default function (pi: ExtensionAPI) {
  const missing: string[] = [];
  for (const provider of OVERRIDES) {
    const catalog = new Map<string, Chat>(
      (getBuiltinModels(provider) as Chat[]).map((model) => [model.id, model]),
    );
    const picked = new Map<string, Chat>();
    for (const id of CURATED[provider]) {
      const model = catalog.get(id);
      if (model) picked.set(id, model);
      else missing.push(`${provider}/${id}`);
    }
    if (provider !== "anthropic") {
      for (const model of catalog.values()) if (isFree(model)) picked.set(model.id, model);
    }
    const models = [...picked.values()].filter((model) => !HIDDEN.has(`${provider}/${model.id}`));
    // No models means "leave the provider as pi configured it" rather than an
    // empty picker entry.
    if (models.length > 0) pi.registerProvider(provider, { models });
  }
  if (missing.length > 0) {
    const message = `curated-models: pi's catalog lacks ${missing.join(", ")}`;
    pi.on("session_start", (_event, ctx) => ctx.ui.notify(message, "warning"));
  }
}
