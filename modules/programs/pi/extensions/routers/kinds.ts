/**
 * The ladders behind the virtual models in ../routers.ts.
 *
 * A kind is one capability tier. Its ladder is a list of **stages**, one per
 * subscription pool, tried in order; a stage holds the models that can do the
 * kind's job on that pool, preferred first.
 *
 * Both subscriptions meter one shared pool per plan, so a model is not a rung of
 * its own: exhausting GLM-5.3 exhausts Kimi K3 with it. What varies *inside* a
 * stage is only which model fits the turn — GLM-5.3 is text-only, so an
 * image-bearing turn takes the next variant that can read it. What varies
 * *between* stages is price: each pool is spent where its rates sting least.
 *
 * - `flash` runs on Go first. Go's DeepSeek rate is 1.4x Synthetic's, cheap
 *   enough that spending the monthly Go pool on bulk traffic costs little, and
 *   it keeps Synthetic's pool for the models only its discount makes affordable
 *   (Go's GLM-5.3 rate is 3.6x Synthetic's, Kimi K3's is 1.4x).
 * - `strong` therefore runs on Synthetic first, Go second.
 *
 * The Anthropic credit is a pool of its own, reserving CREDIT_RESERVE_USD in
 * ../routers.ts. Opus and Sonnet draw the same credit, so a Sonnet stage after
 * Opus could never be reached; Sonnet stays a model to pick by hand.
 */
import type { ThinkingLevel } from "@earendil-works/pi-ai";

export type Provider = "opencode-go" | "synthetic" | "anthropic";

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
const glm: Variant = { id: "glm-5.3", vision: false };
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

/**
 * Domain gaps, second opinions, and the escape hatch for work Claude-lineage
 * models decline. No Anthropic stage on purpose: a refusal from a Claude model
 * would look like a successful turn, so running out has to fail loudly instead.
 */
export const STRONG: Ladder = [
  {
    provider: "synthetic",
    label: "Synthetic",
    variants: [{ id: "hf:zai-org/GLM-5.3", vision: false }, { id: "hf:moonshotai/Kimi-K3" }],
  },
  {
    provider: "opencode-go",
    label: "OpenCode Go",
    variants: [glm, kimi],
  },
];

/** Opus first while the credit lasts, then the strong kinds's pools. */
export const PLANNER: Ladder = [
  { provider: "anthropic", label: "the Anthropic credit", variants: [{ id: "claude-opus-5-5" }] },
  ...STRONG,
];

export const KINDS = { flash: FLASH, strong: STRONG, planner: PLANNER } as const;
export type Kind = keyof typeof KINDS;

/** Display metadata; thinking levels are clamped per routed model by pi. */
export const KIND_META: Record<
  Kind,
  { name: string; thinkingLevels: ThinkingLevel[]; contextWindow: number }
> = {
  flash: { name: "Flash", thinkingLevels: ["low", "high", "max"], contextWindow: 524_288 },
  strong: { name: "Strong", thinkingLevels: ["low", "high", "max"], contextWindow: 524_288 },
  planner: {
    name: "Planner",
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
