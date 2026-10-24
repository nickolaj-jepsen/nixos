/**
 * The ladders behind the virtual models in ../routers.ts.
 *
 * A kind is one capability tier. Its ladder is a list of **stages**, one per
 * subscription pool, tried in order; a stage holds the models that can do the
 * kind's job on that pool, preferred first.
 *
 * Go and Synthetic each meter one shared pool per plan, so a model is not a rung
 * of its own: exhausting Kimi K3.1 Pro on Go exhausts Kimi K3 with it. The Kimi
 * Code plan meters one pool across the Kimi apps too, so strong turns there
 * spend the same allowance the chat clients draw from. What varies *inside* a
 * stage is only which model fits the turn — a text-only variant is skipped
 * while the conversation carries an image. What varies *between* stages is
 * price: each pool is spent where its rates sting least.
 *
 * - `flash` runs on Go first. Go's DeepSeek rate is 1.4x Synthetic's, cheap
 *   enough that spending the monthly Go pool on bulk traffic costs little, and
 *   it keeps Synthetic's pool for the models only its discount makes affordable
 *   (Kimi K3's Go rate is double Synthetic's).
 * - `strong` starts on the Kimi Code plan: that quota is prepaid and costs
 *   nothing at the margin until it resets, so nothing priced per token runs
 *   ahead of it. Synthetic follows, and Go is last, for when the plan's window
 *   is out.
 *
 * The order above is each pool's steady-state ranking; ../routers.ts bends it two
 * ways at pick time. Background requests (compaction summaries) try the credit
 * stage last, so it is spent on background work only when every other pool
 * is out. And Go's monthly allowance is bankable — whatever it holds at its
 * reset strands, while Synthetic's weekly meter refills continuously and can
 * never be banked — so while Go's window is under pace near its reset, its
 * stage swaps ahead of Synthetic's. Both pools carry the same models, so only
 * which meter drains changes.
 *
 * The Anthropic credit is a pool of its own, reserving CREDIT_RESERVE_USD in
 * ../routers.ts. Opus and Sonnet draw the same credit, so a Sonnet stage after
 * Opus could never be reached; Sonnet stays a model to pick by hand.
 */
import type { ThinkingLevel } from "@earendil-works/pi-ai";

export type Provider = "opencode-go" | "synthetic" | "anthropic" | "kimi-coding";

export type Variant = {
  id: string;
  /** False for a text-only model: skipped while the conversation has images. */
  vision?: boolean;
};

export type Stage = {
  provider: Provider;
  /** For switch notices: what ran out. */
  label: string;
  /** Preferred first; the router takes the first that fits the turn. */
  variants: readonly Variant[];
};

export type Ladder = readonly Stage[];

const deepseek: Variant = { id: "deepseek-v4.1-flash" };
const kimiPlan: Variant = { id: "k3.1-pro" };
const kimiPro: Variant = { id: "kimi-k3.1-pro" };
const kimi: Variant = { id: "kimi-k3" };

/**
 * Cheapest model that is still frontier-grade: DeepSeek V4.1 Flash matches the
 * expensive tier on intelligence for a fraction of the price, so it drives
 * ordinary turns. Haiku is the last stage, for the kind where a quality drop is
 * acceptable.
 */
export const FLASH: Ladder = [
  { provider: "opencode-go", label: "OpenCode Go", variants: [deepseek] },
  {
    provider: "synthetic",
    label: "Synthetic",
    variants: [{ id: "hf:deepseek-ai/DeepSeek-V4.1-Flash" }],
  },
  { provider: "anthropic", label: "the Anthropic credit", variants: [{ id: "claude-haiku-5-5" }] },
];

const kimiCode: Stage = {
  provider: "kimi-coding",
  label: "Kimi Code",
  variants: [kimiPlan],
};

/**
 * Domain gaps, second opinions, and the escape hatch for work Claude-lineage
 * models decline. No Anthropic stage on purpose: a refusal from a Claude model
 * would look like a successful turn, so running out has to fail loudly instead.
 */
export const STRONG: Ladder = [
  kimiCode,
  {
    provider: "synthetic",
    label: "Synthetic",
    variants: [kimi],
  },
  {
    provider: "opencode-go",
    label: "OpenCode Go",
    variants: [kimiPro],
  },
];

const opus: Stage = {
  provider: "anthropic",
  label: "the Anthropic credit",
  variants: [{ id: "claude-opus-5-5" }],
};

/** Opus first while the credit lasts, then the strong kind's pools. */
export const PLANNER: Ladder = [opus, ...STRONG];

/** The architect's complex path: K3.1 Pro on the Kimi Code plan first, then Opus, then the rest of the strong pools. */
export const ARCHITECT_PLANNER: Ladder = [kimiCode, opus, ...STRONG.slice(1)];

export const KINDS = { flash: FLASH, strong: STRONG, planner: PLANNER } as const;
export type Kind = keyof typeof KINDS;

/** The namespace the virtual models are listed under: vm/flash, vm/strong, … */
export const PROVIDER = "vm";

/** Every virtual model's ladder keyed as pi lists it; architect is the planner
 * and flash ladders flattened in dispatch order, for registries that display. */
export const LADDERS: Record<Kind | "architect", Ladder> = {
  ...KINDS,
  architect: [...ARCHITECT_PLANNER, ...FLASH],
};

export type ModelMeta = {
  name: string;
  /** One line for /models; this file's header is the long form. */
  description: string;
  thinkingLevels: ThinkingLevel[];
  contextWindow: number;
};

/** Display metadata for every virtual model in ../routers.ts; pi clamps thinking levels per routed model. */
export const KIND_META: Record<Kind | "architect", ModelMeta> = {
  flash: {
    name: "Flash",
    description: "Cheap frontier for ordinary turns",
    thinkingLevels: ["low", "high", "max"],
    contextWindow: 524_288,
  },
  strong: {
    name: "Strong",
    description: "Second opinion, and the escape hatch Claude models decline",
    thinkingLevels: ["low", "high", "max"],
    contextWindow: 524_288,
  },
  planner: {
    name: "Planner",
    description: "Opus plans while the credit lasts",
    thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
    contextWindow: 1_000_000,
  },
  architect: {
    name: "Architect",
    description: "Hard problems planned on the planner, everything else on Flash",
    thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
    contextWindow: 1_000_000,
  },
};

export type Tone = "normal" | "warn" | "alert";

/**
 * How much the model that is answering should worry the user: the first stage of
 * a kind is neutral, a later stage means the preferred pool ran out, and anything
 * on the Anthropic credit is an alert because it spends the reserve.
 *
 * Takes a physical model, so one reached outside the kinds reads as neutral.
 */
export const stageTone = (provider: string, id: string): Tone => {
  if (provider === "anthropic") return "alert";
  const depths = Object.values(KINDS).flatMap((ladder) =>
    ladder.flatMap((stage, index) =>
      stage.provider === provider && stage.variants.some((variant) => variant.id === id)
        ? [index]
        : [],
    ),
  );
  if (depths.length === 0) return "normal";
  return Math.min(...depths) === 0 ? "normal" : "warn";
};
