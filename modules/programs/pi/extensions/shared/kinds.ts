/**
 * The ladders behind the virtual models in ../core/routers.ts: one stage per
 * subscription pool, tried in order. Why each ladder is ordered the way it is
 * lives in docs/models.md.
 */
import type { ThinkingLevel } from "@earendil-works/pi-ai";

export type Provider = "opencode-go" | "synthetic" | "anthropic" | "kimi-coding";

export type Stage = {
  provider: Provider;
  id: string;
  /** For switch notices: what ran out. */
  label: string;
};

export type Ladder = readonly Stage[];

export const FLASH: Ladder = [
  { provider: "opencode-go", id: "deepseek-v4.1-flash", label: "OpenCode Go" },
  { provider: "synthetic", id: "hf:deepseek-ai/DeepSeek-V4.1-Flash", label: "Synthetic" },
  { provider: "anthropic", id: "claude-sonnet-5-5", label: "the Anthropic credit" },
];

/** No Go stage: Go is kept for flash, so running out here fails loudly instead. */
export const DEEP: Ladder = [
  { provider: "kimi-coding", id: "k3.1-pro", label: "Kimi Code" },
  { provider: "anthropic", id: "claude-opus-5-5", label: "the Anthropic credit" },
  { provider: "synthetic", id: "hf:moonshotai/Kimi-K3", label: "Synthetic" },
];

export const KINDS = { flash: FLASH, deep: DEEP } as const;
export type Kind = keyof typeof KINDS;

/** The namespace the virtual models are listed under: vm/flash, vm/deep, … */
export const PROVIDER = "vm";

/** Every virtual model's ladder keyed as pi lists it; architect is deep then flash, for registries that display. */
export const LADDERS: Record<Kind | "architect", Ladder> = {
  ...KINDS,
  architect: [...DEEP, ...FLASH],
};

/** What a kind's router keeps per selection: `at` is the stage index on the ladder in use. */
export type KindState = { at: number };

export type ArchitectPhase = "plan" | "build";
/** What vm/architect keeps per selection; readers outside the router use only `phase`. */
export type ArchitectState = { phase: ArchitectPhase; at: number; verdict?: boolean };

export type ModelMeta = {
  name: string;
  /** One line for /models; docs/models.md is the long form. */
  description: string;
  thinkingLevels: ThinkingLevel[];
  contextWindow: number;
};

/** Display metadata for every virtual model in ../core/routers.ts; pi clamps thinking levels per routed model. */
export const KIND_META: Record<Kind | "architect", ModelMeta> = {
  flash: {
    name: "Flash",
    description: "Cheap frontier for ordinary turns",
    thinkingLevels: ["low", "high", "max"],
    contextWindow: 524_288,
  },
  deep: {
    name: "Deep",
    description: "Hard work on the Kimi plan, then the credit",
    thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
    contextWindow: 1_000_000,
  },
  architect: {
    name: "Architect",
    description: "Hard problems planned on Deep, everything else on Flash",
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
      stage.provider === provider && stage.id === id ? [index] : [],
    ),
  );
  if (depths.length === 0) return "normal";
  return Math.min(...depths) === 0 ? "normal" : "warn";
};
