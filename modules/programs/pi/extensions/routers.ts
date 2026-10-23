/**
 * Virtual models (see pi's docs/virtual-models.md):
 *
 * - `fp/flash`: DeepSeek V4.1 Flash on OpenCode Go. Only while Go's quota is
 *   used up does it bridge to Claude Haiku on the Anthropic credit, and it
 *   returns at the first prompt after Go's window resets. Otherwise a session
 *   stays on one model, so the prompt cache stays warm.
 * - `fp/architect`: Opus explores, plans and makes the first edit; from the next
 *   request on, the session continues on `fp/flash`'s model. `/replan` sends the
 *   next prompt back to Opus.
 *
 * Go's quota comes from ai-usage, and from Go's own limit errors, which pi does
 * not retry, so those never reach `route()` as a retry: the extension flags
 * them and continues the interrupted turn on the bridge.
 */
import type { Message } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  ExtensionContext,
  ModelRoute,
  ModelRouteRequest,
} from "@earendil-works/pi-coding-agent";
import { createUsageReader, exhaustedWindow } from "./lib/ai-usage.ts";

const PROVIDER = "fp";
const GO = { provider: "opencode-go", id: "deepseek-v4.1-flash" } as const;
const BRIDGE = { provider: "anthropic", id: "claude-haiku-5-5" } as const;
const PLANNER = { provider: "anthropic", id: "claude-opus-5-5" } as const;

type Pool = "go" | "bridge";
const POOLS: Record<Pool, { provider: string; id: string }> = { go: GO, bridge: BRIDGE };

// pi lists these as non-retryable OpenCode Go subscription limits.
const GO_LIMIT_ERROR = /GoUsageLimitError|Monthly usage limit reached|available balance/i;
// How long a limit error blocks Go when ai-usage can't say when it resets.
const GO_BLOCK_FALLBACK_MS = 30 * 60_000;
// Below this the promo credit is spent and the key would bill or fail.
const MIN_CREDIT_USD = 1;

/** Tools whose successful result means implementation has started. */
const EDIT_TOOLS = new Set(["edit", "write"]);

type FlashState = { pool: Pool };
type ArchitectState = { phase: "plan" } | { phase: "build"; pool: Pool };

export default function (pi: ExtensionAPI) {
  const usage = createUsageReader();
  /** Set by a Go limit error; ai-usage alone lags it by up to two minutes. */
  let goBlockedUntil = 0;
  /** A Go limit error ended a turn of one of these models; continue it on the bridge. */
  let resumeAfterLimit = false;
  /** Sessions whose next prompt goes back to the planner. */
  const replan = new Set<string>();

  const goBlocked = () => {
    const window = exhaustedWindow(usage.provider("opencode-go"));
    return Date.now() < goBlockedUntil || window !== undefined;
  };

  const bridgeUsable = () => {
    const credit = usage.provider("anthropic")?.credit;
    return !credit || credit.remaining >= MIN_CREDIT_USD;
  };

  const find = (ctx: ExtensionContext, ref: { provider: string; id: string }) => {
    const model = ctx.modelRegistry.find(ref.provider, ref.id);
    if (!model) throw new Error(`${ref.provider}/${ref.id} is not in the catalog`);
    return model;
  };

  /**
   * The pool for this request: stay put, except to leave Go once its quota is
   * out, or to return to it at a prompt once it is back.
   */
  const choosePool = async (current: Pool | undefined, reason: string): Promise<Pool> => {
    // Only the first decision waits; later ones use the last snapshot.
    if (!usage.known()) await usage.refresh();
    else void usage.refresh();
    if (goBlocked()) return bridgeUsable() ? "bridge" : "go";
    if (current === "bridge" && reason !== "user") return "bridge";
    return "go";
  };

  const notifySwitch = (ctx: ExtensionContext, from: Pool | undefined, to: Pool) => {
    if (!from || from === to || !ctx.hasUI) return;
    ctx.ui.notify(
      to === "bridge"
        ? "OpenCode Go quota is used up: continuing on Claude Haiku (Anthropic credit)"
        : "OpenCode Go quota is back: continuing on DeepSeek",
      "info",
    );
  };

  /** Route within the flash pools, keeping `state` unless the pool changes. */
  const flashRoute = async <S extends object>(
    request: ModelRouteRequest<S>,
    ctx: ExtensionContext,
    current: Pool | undefined,
    withPool: (pool: Pool) => S,
  ): Promise<ModelRoute<S>> => {
    const pool = await choosePool(current, request.reason);
    notifySwitch(ctx, current, pool);
    return {
      model: find(ctx, POOLS[pool]),
      thinkingLevel: request.thinkingLevel,
      state: pool === current ? request.state : withPool(pool),
    };
  };

  pi.registerVirtualModel<FlashState>({
    provider: PROVIDER,
    id: "flash",
    name: "Flash",
    thinkingLevels: ["low", "high", "max"],
    contextWindow: 1_000_000,
    async route(request, ctx) {
      // Retries keep the failed model, so its cache and reasoning replay stay valid.
      if (request.reason === "retry" && request.failed) {
        return { model: request.failed.model, thinkingLevel: request.thinkingLevel };
      }
      if (request.reason === "direct") {
        const pool = await choosePool(undefined, "direct");
        return { model: find(ctx, POOLS[pool]), thinkingLevel: request.thinkingLevel };
      }
      return flashRoute(request, ctx, request.state?.pool, (pool) => ({ pool }));
    },
  });

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
      // Compaction summaries don't need the planner.
      if (request.reason === "direct") {
        const pool = await choosePool(undefined, "direct");
        return { model: find(ctx, POOLS[pool]), thinkingLevel: request.thinkingLevel };
      }
      const state = request.state;
      const sessionId = ctx.sessionManager.getSessionId();
      // Consume a pending /replan even on the first prompt, which plans anyway.
      const replanNow = request.reason === "user" && replan.delete(sessionId);
      if (!state || replanNow) {
        const plan: ArchitectState = { phase: "plan" };
        return {
          model: find(ctx, PLANNER),
          thinkingLevel: request.thinkingLevel,
          state: state?.phase === "plan" ? state : plan,
        };
      }
      if (state.phase === "plan" && !editedThisTurn(request.messages)) {
        return { model: find(ctx, PLANNER), thinkingLevel: request.thinkingLevel };
      }
      // The planner made the first edit: the rest goes to the flash pools.
      const current = state.phase === "build" ? state.pool : undefined;
      return flashRoute(request, ctx, current, (pool) => ({ phase: "build", pool }));
    },
  });

  pi.registerCommand("replan", {
    description: "Send the next prompt (or the given one) to fp/architect's planner",
    handler: async (args, ctx) => {
      // Only fp/architect consumes the entry; on any other model it would wait for a later switch.
      if (ctx.model?.provider !== PROVIDER || ctx.model.id !== "architect") {
        ctx.ui.notify("/replan only applies while fp/architect is the model", "warning");
        return;
      }
      replan.add(ctx.sessionManager.getSessionId());
      const prompt = args.trim();
      if (prompt) pi.sendUserMessage(prompt, ctx.isIdle() ? undefined : { deliverAs: "followUp" });
      else ctx.ui.notify("The next prompt goes to Opus", "info");
    },
  });

  const routedHere = (ctx: ExtensionContext) => ctx.model?.provider === PROVIDER;

  pi.on("message_end", (event, ctx) => {
    const message = event.message;
    if (
      message.role !== "assistant" ||
      message.stopReason !== "error" ||
      message.provider !== GO.provider ||
      !GO_LIMIT_ERROR.test(message.errorMessage ?? "")
    ) {
      return;
    }
    goBlockedUntil = Date.now() + GO_BLOCK_FALLBACK_MS;
    resumeAfterLimit = routedHere(ctx) && bridgeUsable();
    // Go's usage can lag its own limit errors, so only a window that is out moves the block.
    void usage.refresh({ force: true }).then(() => {
      const window = exhaustedWindow(usage.provider(GO.provider));
      if (window) goBlockedUntil = Date.parse(window.resetsAt);
    });
  });

  // Continuing before the run settles keeps settle listeners from seeing it finish and restart.
  pi.on("agent_before_settle", (event, ctx) => {
    if (!resumeAfterLimit) return;
    resumeAfterLimit = false;
    if (event.outcome === "aborted" || !routedHere(ctx)) return;
    return {
      entries: [
        ...event.entries,
        {
          type: "custom_message",
          customType: "fp-router",
          content: "OpenCode Go's quota ran out mid-turn. Continue where you left off.",
          display: true,
        },
      ],
      continue: true,
    };
  });

  // An aborted run skips agent_before_settle; the flag must not carry into the next one.
  pi.on("agent_settled", () => {
    resumeAfterLimit = false;
  });
}

/** Whether a tool call since the last user message edited a file successfully. */
function editedThisTurn(messages: readonly Message[]): boolean {
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    if (message.role === "user") return false;
    if (message.role !== "toolResult") continue;
    if (EDIT_TOOLS.has(message.toolName) && !message.isError) return true;
    // A codemode script's edits only show up as nested calls; they count even if the script failed later.
    if (message.nestedCalls?.calls.some((c) => EDIT_TOOLS.has(c.name) && c.status === "ok")) {
      return true;
    }
  }
  return false;
}
