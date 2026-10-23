/**
 * Virtual models (see pi's docs/virtual-models.md), one per kind, with the
 * ladders themselves in ./routers/kinds.ts:
 *
 * - `fp/flash`: DeepSeek V4.1 Flash on OpenCode Go, then on Synthetic, then Haiku
 *   on the Anthropic credit. Frontier-grade intelligence for a fraction of the
 *   price, so it drives ordinary turns.
 * - `fp/strong`: GLM-5.3 and Kimi K3, Synthetic then Go, and no Anthropic stage —
 *   the second opinion and the escape hatch for work Claude-lineage models
 *   decline, so it fails loudly instead of tailing into one.
 * - `fp/planner`: Opus while the credit lasts, then the strong kind's pools.
 * - `fp/architect`: the first step plans on `fp/planner`, and once the planner has
 *   made an edit the session continues on `fp/flash`. `/replan` sends the next
 *   prompt back to the planner.
 *
 * A kind only ever walks its own ladder; nothing escalates to a pricier kind on
 * its own. Each subscription meters one shared pool, so a stage is a pool, not a
 * model: availability is asked once per provider, and the model chosen inside a
 * stage is whichever fits the turn. Request counts come from ai-usage (`ai-usage
 * --json`) and from each provider's own limit errors, which pi does not retry, so
 * those never reach `route()` as a retry: the extension flags them and continues
 * the interrupted turn one stage down. No kind spends the Anthropic credit below
 * CREDIT_RESERVE_USD, which keeps it as a reserve to spend by hand.
 */
import type { Message, ThinkingLevel } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  ExtensionContext,
  ModelRoute,
  ModelRouteRequest,
} from "@earendil-works/pi-coding-agent";
import { createUsageReader, exhaustedWindow } from "./lib/ai-usage.ts";
import {
  FLASH,
  KIND_META,
  KINDS,
  PLANNER,
  type Kind,
  type Ladder,
  type Stage,
} from "./routers/kinds.ts";

const PROVIDER = "fp";
/** Below this the Anthropic credit is the reserve; no kind spends it. */
const CREDIT_RESERVE_USD = 20;
const PROVIDER_NAME: Record<string, string> = {
  "opencode-go": "OpenCode Go",
  synthetic: "Synthetic",
};
// The providers whose own subscription limits pi lists as non-retryable.
const LIMIT_ERROR: Record<string, RegExp> = {
  "opencode-go": /GoUsageLimitError|Monthly usage limit reached|available balance/i,
  synthetic: /quota|credit|rate.?limit|429/i,
};
// How long a limit error blocks a provider when ai-usage can't say when it comes back.
const GO_BLOCK_FALLBACK_MS = 30 * 60_000;
// Synthetic regenerates 2% of the weekly credit every 202 minutes, so a spent
// meter is usable again at the next tick, which ai-usage does not report.
const SYNTHETIC_REFILL_MS = 202 * 60_000;
// A limit error ai-usage does not corroborate: let the turn finish, then retry.
const UNCORROBORATED_BLOCK_MS = 60_000;

/** Tools whose successful result means implementation has started. */
const EDIT_TOOLS = new Set(["edit", "write"]);

/** A place on a ladder: the stage (pool) and the model inside it. */
type Position = { stage: number; model: number };
type KindState = { at: Position };
type ArchitectState = { phase: "plan" | "build"; at: Position };

export default function (pi: ExtensionAPI) {
  const usage = createUsageReader();
  /** Per provider, set by its own limit errors; ai-usage alone lags them. */
  const blockedUntil: Record<string, number> = {};
  /** The provider a limit error stopped; its turn continues one stage down. */
  let resumeAfter: string | undefined;
  /** Sessions whose next prompt goes back to the planner. */
  const replan = new Set<string>();

  /** Whether ai-usage has the provider out of quota right now. */
  const spent = (provider: string) => exhaustedWindow(usage.provider(provider)) !== undefined;

  /** The credit is the reserve: below it no kind spends Anthropic at all. */
  const creditAboveReserve = () => {
    const credit = usage.provider("anthropic")?.credit;
    return !credit || credit.remaining >= CREDIT_RESERVE_USD;
  };

  /** A stage is its pool: every model on it shares one allowance. */
  const stageReady = (stage: Stage) =>
    stage.provider === "anthropic"
      ? creditAboveReserve()
      : Date.now() >= (blockedUntil[stage.provider] ?? 0) && !spent(stage.provider);

  const find = (ctx: ExtensionContext, stage: Stage, model: number) => {
    const variant = stage.variants[model];
    const found = ctx.modelRegistry.find(stage.provider, variant.id);
    if (!found) throw new Error(`${stage.provider}/${variant.id} is not in the catalog`);
    return found;
  };

  /**
   * Where to send this request: the first ready stage from `from` on, taking the
   * model that fits the turn (a text-only one is skipped while the conversation
   * carries images). `from` is the current position for a continuation, so a
   * working model keeps its prompt cache; a fresh prompt starts at the top of the
   * ladder so a recovered pool is used again.
   */
  const pick = async (
    ladder: Ladder,
    from: Position | undefined,
    messages: readonly Message[],
  ): Promise<Position> => {
    // Only the first decision waits; later ones use the last snapshot.
    if (!usage.known()) await usage.refresh();
    else void usage.refresh();
    const images = hasImages(messages);
    const fits = (stage: Stage, model: number) => !images || stage.variants[model].vision !== false;

    const search = (start: number, end: number): Position | undefined => {
      for (let s = start; s < end; s++) {
        const stage = ladder[s];
        if (!stageReady(stage)) continue;
        // Staying on the same model keeps the cache; otherwise the preferred one.
        const preferred = from?.stage === s && fits(stage, from.model) ? from.model : 0;
        for (const m of [preferred, ...stage.variants.keys()]) {
          if (fits(stage, m)) return { stage: s, model: m };
        }
      }
      return undefined;
    };

    const start = from?.stage ?? 0;
    // Down the ladder first, then up it, for a pool that recovered mid-turn.
    return search(start, ladder.length) ?? search(0, start) ?? from ?? { stage: 0, model: 0 };
  };

  /** Route within one kind's ladder, keeping `state` unless the position changes. */
  const routeKind = async <S extends object>(
    ladder: Ladder,
    request: ModelRouteRequest<S>,
    ctx: ExtensionContext,
    current: Position | undefined,
    withAt: (at: Position) => S,
  ): Promise<ModelRoute<S>> => {
    // Retries keep the failed model, so its cache and reasoning replay stay valid.
    if (request.reason === "retry" && request.failed) {
      return { model: request.failed.model, thinkingLevel: request.thinkingLevel };
    }
    // A new prompt walks the whole ladder again; anything else starts where it is.
    const fresh = request.reason === "user" || request.reason === "direct";
    const at = await pick(ladder, fresh ? undefined : current, request.messages);
    if (current && current.stage !== at.stage) {
      notifySwitch(ctx, ladder[current.stage], ladder[at.stage], at.stage > current.stage);
    }
    return {
      model: find(ctx, ladder[at.stage], at.model),
      thinkingLevel: request.thinkingLevel,
      state: samePosition(current, at) ? request.state : withAt(at),
    };
  };

  const notifySwitch = (ctx: ExtensionContext, from: Stage, to: Stage, down: boolean) => {
    if (!ctx.hasUI) return;
    ctx.ui.notify(
      down
        ? `${from.label} is used up: continuing on ${to.label}`
        : `${to.label} is back: continuing on it`,
      "info",
    );
  };

  const register = (
    id: string,
    ladder: Ladder,
    meta: { name: string; thinkingLevels: ThinkingLevel[]; contextWindow: number },
  ) =>
    pi.registerVirtualModel<KindState>({
      provider: PROVIDER,
      id,
      name: meta.name,
      thinkingLevels: meta.thinkingLevels,
      contextWindow: meta.contextWindow,
      route: (request, ctx) =>
        routeKind<KindState>(ladder, request, ctx, request.state?.at, (at) => ({ at })),
    });

  for (const kind of Object.keys(KINDS) as Kind[]) register(kind, KINDS[kind], KIND_META[kind]);

  pi.registerVirtualModel<ArchitectState>({
    provider: PROVIDER,
    id: "architect",
    name: "Architect",
    thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
    contextWindow: 1_000_000,
    async route(request, ctx) {
      if (request.reason === "retry" && request.failed) {
        return { model: request.failed.model, thinkingLevel: request.thinkingLevel };
      }
      if (request.reason === "direct") {
        const at = await pick(FLASH, undefined, request.messages);
        return {
          model: find(ctx, FLASH[at.stage], at.model),
          thinkingLevel: request.thinkingLevel,
        };
      }
      const state = request.state;
      const sessionId = ctx.sessionManager.getSessionId();
      const startPlanning = !state || (request.reason === "user" && replan.delete(sessionId));
      if (startPlanning || (state.phase === "plan" && !editedThisTurn(request.messages))) {
        // The first step plans on the planner kind, whatever pool that lands on.
        const at = startPlanning ? undefined : state.at;
        return routeKind(PLANNER, request, ctx, at, (position) => ({
          phase: "plan",
          at: position,
        }));
      }
      // The planner made the first edit: the rest goes to the flash ladder.
      const at = state.phase === "build" ? state.at : undefined;
      return routeKind(FLASH, request, ctx, at, (position) => ({ phase: "build", at: position }));
    },
  });

  pi.registerCommand("replan", {
    description: "Send the next prompt (or the given one) to fp/architect's planner",
    handler: async (args, ctx) => {
      replan.add(ctx.sessionManager.getSessionId());
      if (args.trim()) pi.sendUserMessage(args.trim());
      else ctx.ui.notify("The next prompt goes to the planner", "info");
    },
  });

  const routedHere = (ctx: ExtensionContext) => ctx.model?.provider === PROVIDER;

  pi.on("message_end", async (event, ctx) => {
    const message = event.message;
    if (message.role !== "assistant" || message.stopReason !== "error") return;
    const provider = message.provider;
    if (!LIMIT_ERROR[provider]?.test(message.errorMessage ?? "")) return;
    await usage.refresh();
    if (provider === "opencode-go") {
      const window = exhaustedWindow(usage.provider(provider));
      blockedUntil[provider] = window
        ? Date.parse(window.resetsAt)
        : Date.now() + GO_BLOCK_FALLBACK_MS;
    } else {
      // The error can land before ai-usage's next refresh; the meter's tick is the real wait.
      blockedUntil[provider] =
        Date.now() + (spent(provider) ? SYNTHETIC_REFILL_MS : UNCORROBORATED_BLOCK_MS);
    }
    // Continue the turn only if that block left another pool to continue on.
    const elsewhere = Object.values(KINDS).some((ladder) =>
      ladder.some((stage) => stage.provider !== provider && stageReady(stage)),
    );
    if (routedHere(ctx) && elsewhere) resumeAfter = provider;
  });

  pi.on("agent_settled", (event, ctx) => {
    const ended = resumeAfter;
    resumeAfter = undefined;
    if (!ended || event.aborted || !routedHere(ctx)) return;
    pi.sendMessage(
      {
        customType: "fp-router",
        content: `${PROVIDER_NAME[ended] ?? ended} ran out of quota mid-turn. Continue where you left off.`,
        display: true,
      },
      { triggerTurn: true },
    );
  });
}

/** Whether two positions point at the same pool and model. */
const samePosition = (a: Position | undefined, b: Position) =>
  a?.stage === b.stage && a.model === b.model;

/** Whether any message in the conversation carries an image. */
function hasImages(messages: readonly Message[]): boolean {
  return messages.some((message) => {
    const content = (message as { content?: unknown }).content;
    return (
      Array.isArray(content) &&
      content.some((block) => (block as { type?: string }).type === "image")
    );
  });
}

/** Whether a tool call since the last user message edited a file successfully. */
function editedThisTurn(messages: readonly Message[]): boolean {
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    if (message.role === "user") return false;
    if (message.role === "toolResult" && EDIT_TOOLS.has(message.toolName) && !message.isError) {
      return true;
    }
  }
  return false;
}
