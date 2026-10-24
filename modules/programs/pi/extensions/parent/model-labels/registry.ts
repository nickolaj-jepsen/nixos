/**
 * What each model's data handling looks like, as the glyphs /models
 * (../model-labels.ts) draws next to it. Labelling only: nothing here routes or
 * refuses.
 *
 * The labels are the *exception*, not the rule: a model earns `zdr`, `eu` and
 * `local` when it can, and gets a red mark when it retains prompts or trains on
 * them, so a quiet row means "nothing to report". `no-train` is deliberately
 * absent, because untrained is the baseline; `trains` is what stands out.
 *
 * Policy labels sit on a provider when its policy covers every model on it, and
 * a model entry adds a label or takes one back with `-label`. `text-only` is
 * derived from pi's catalogue, so a model that gains vision relabels itself.
 */
import { KIND_META, LADDERS, PROVIDER, type Ladder } from "../../shared/kinds.ts";

type LabelSpec = { meaning: string; glyph: string; color?: string };

export type Label = keyof typeof SPECS;

/**
 * The closed set, in display order. Colours are hexes from
 * modules/base/theme.nix, because a glyph needs a colour the theme has no token
 * for and the theme is pinned (not `system`). Glyphs are Material Design Icons
 * from the Nerd Font the terminal is set to.
 */
const SPECS = {
  zdr: { meaning: "nothing retained", glyph: "\u{f0565}", color: "#879A39" },
  retains: { meaning: "kept for a while", glyph: "\u{f174f}", color: "#D14D41" },
  trains: { meaning: "may train on prompts", glyph: "\u{f0093}", color: "#D14D41" },
  eu: { meaning: "EU datacenters", glyph: "\u{f01e7}", color: "#4385BE" },
  local: { meaning: "runs on this machine", glyph: "\u{f02dc}", color: "#8B7EC8" },
  /** Derived, not policy: the only capability fact the picker draws. */
  "text-only": { meaning: "no image input", glyph: "\u{f082b}" },
} as const satisfies Record<string, LabelSpec>;

export const LABELS: Record<Label, LabelSpec> = SPECS;

type Delta = Label | `-${Label}`;

/**
 * https://synthetic.new/policies/privacy — "We do not store model prompts or
 * completions from the API" and never train on them. Servers are in the US and
 * the EU with no EU-only routing, so no `eu`.
 */
const SYNTHETIC: readonly Label[] = ["zdr"];

/**
 * https://opencode.ai/docs/go/ — its per-model table gives 0-day retention and
 * "Not used" training for the models below, with the exceptions in MODELS.
 * Hosted in the US, the EU and Singapore, so no `eu`.
 */
const GO: readonly Label[] = ["zdr"];

const PROVIDERS: Record<string, readonly Label[]> = {
  synthetic: SYNTHETIC,
  "opencode-go": GO,
  /**
   * https://www.kimi.com/en/privacy — the consumer membership keeps prompts with
   * the account and the terms state no zero-retention option outside the
   * enterprise API, so `zdr` is not claimed.
   */
  "kimi-coding": ["retains"],
  /** https://tensorx.ai/trust-security/ — memory-only inference on EU GPUs in Dublin and Helsinki. */
  tensorx: ["zdr", "eu"],
  /** https://privacy.anthropic.com/en/articles/10023548-how-long-do-you-store-my-data — 30 days. */
  anthropic: ["retains"],
  /** llama-swap on this host (modules/programs/llm.nix). */
  local: ["local"],
};

/** Exceptions to the provider's row in the docs cited above. */
const MODELS: Record<string, readonly Delta[]> = {
  // Go's 30-day retention models: https://opencode.ai/docs/go/ "Data retention".
  "opencode-go/claude-haiku-5-5": ["-zdr", "retains"],
  "opencode-go/gpt-6-luna": ["-zdr", "retains"],
  "opencode-go/gpt-5.6-luna": ["-zdr", "retains"],
  "opencode-go/grok-4.7": ["-zdr", "retains"],
  "opencode-go/beam-free": ["-zdr", "retains"],
  // Go's contributor tiers trade prompts for training: same table.
  "opencode-go/gemini-4-argon-contributor": ["-zdr", "retains", "trains"],
  "opencode-go/muse-spark-1.2-contributor": ["-zdr", "retains", "trains"],
  "opencode-go/muse-spark-1.3-contributor": ["-zdr", "retains", "trains"],
};

/** The part of a catalogue model that labelling reads. */
export type CatalogModel = {
  provider: string;
  id: string;
  input?: readonly string[];
};

type Find = (provider: string, id: string) => CatalogModel | undefined;

/** Labels that are a risk rather than a promise: true for a kind if *any* stage has them. */
const RISK: ReadonlySet<Label> = new Set<Label>(["retains", "trains"]);

/**
 * A model's labels, ordered as `LABELS`. A virtual model (`vm/*`) promises only
 * what every model on its ladder does, so one stage on a retaining model takes
 * `zdr` off the whole kind; a risk shows up if any stage has it, because that is
 * the stage a spent pool can land on.
 */
export const labelsFor = (model: CatalogModel, find: Find): Label[] => {
  const labels = new Set<Label>(
    model.provider === PROVIDER ? virtualLabels(model.id, find) : providerLabels(model),
  );
  return (Object.keys(LABELS) as Label[]).filter((label) => labels.has(label));
};

/** The one-line description /models shows next to a virtual model; physical models have none. */
export const descriptionFor = (model: CatalogModel): string =>
  model.provider === PROVIDER
    ? (KIND_META[model.id as keyof typeof KIND_META]?.description ?? "")
    : "";

const providerLabels = (model: CatalogModel): Label[] => {
  const labels = new Set<Label>(PROVIDERS[model.provider] ?? []);
  for (const delta of MODELS[`${model.provider}/${model.id}`] ?? []) {
    if (delta.startsWith("-")) labels.delete(delta.slice(1) as Label);
    else labels.add(delta as Label);
  }
  if (model.input && !model.input.includes("image")) labels.add("text-only");
  return [...labels];
};

/**
 * What a virtual model can promise and what it can run into: the facts every
 * model on its ladder shares, plus the risks any of them carries. A model
 * missing from the catalogue is skipped, since it cannot be reached.
 */
const virtualLabels = (id: string, find: Find): Label[] => {
  const ladder = LADDERS[id as keyof typeof LADDERS] as Ladder | undefined;
  if (!ladder) return [];
  let shared: Set<Label> | undefined;
  const anywhere = new Set<Label>();
  for (const stage of ladder) {
    const model = find(stage.provider, stage.id);
    if (!model) continue;
    const labels = new Set(providerLabels(model));
    for (const label of labels) if (RISK.has(label)) anywhere.add(label);
    shared = shared ? new Set([...shared].filter((label) => labels.has(label))) : labels;
  }
  const labels = new Set<Label>([
    ...[...(shared ?? [])].filter((label) => !RISK.has(label)),
    ...anywhere,
  ]);
  return (Object.keys(LABELS) as Label[]).filter((label) => labels.has(label));
};
