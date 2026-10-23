/**
 * Virtual models (see pi's docs/virtual-models.md), one per kind, with the
 * ladders and one-line descriptions in ./routers/kinds.ts: `vm/flash`,
 * `vm/strong`, `vm/planner` and `vm/architect`, whose rated planning entries
 * run on the planner or flash, and whose build phase runs on flash until
 * `/replan` sends the next prompt back to planning.
 *
 * A kind only ever walks its own ladder; nothing escalates to a pricier kind on
 * its own. Each subscription meters one shared pool, so a stage is a pool, not
 * a model: availability is asked once per provider, and the model chosen inside
 * a stage is whichever fits the turn. Request counts come from ai-usage
 * (`ai-usage --json`) and from each provider's own limit errors, which pi does
 * not retry, so those never reach `route()` as a retry: the extension flags them
 * and continues the interrupted turn one stage down. No kind spends the
 * Anthropic credit below CREDIT_RESERVE_USD, which keeps it as a reserve to
 * spend by hand.
 *
 * Three bends on top of the ladder order, all visible in `/vm`:
 * - Background requests (`reason: "direct"`, e.g. compaction summaries) hold
 *   the credit stage back to last, so it serves background work only when both
 *   subscriptions are out.
 * - While Go's monthly window is under pace near its reset (kinds.ts: bankable
 *   allowance about to strand), its stage swaps ahead of Synthetic's.
 * - The architect's planning entry is rated by Jev (typesafe/jev-latest):
 *   standard prompts plan on flash, complex prompts on the planner, and no
 *   verdict fails open to the planner — the gate is an optimisation, not a
 *   policy. GLM-5.3 sits past Opus in the planner ladder: it is reached only
 *   when a genuinely hard problem outlives the credit, the only place its
 *   edge over DS 4.1 Flash is worth its price.
 * - The plan→build boundary re-rates the finished plan on the same question
 *   (shadow): the verdict is marked in the chat and kept in the /vm trace
 *   but never acted on, until it has earned a threshold on real sessions.
 */
import type { Message, ThinkingLevel } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  ExtensionContext,
  ModelRoute,
  ModelRouteRequest,
} from "@earendil-works/pi-coding-agent";
import { createUsageReader, exhaustedWindow, type UsageProvider } from "./lib/ai-usage.ts";
import {
  FLASH,
  KIND_META,
  KINDS,
  PLANNER,
  PROVIDER,
  STRONG,
  type Kind,
  type Ladder,
  type Stage,
} from "./routers/kinds.ts";

/** Below this the Anthropic credit is the reserve; no kind spends it. */
const CREDIT_RESERVE_USD = 20;
const PROVIDER_NAME: Record<string, string> = {
  "opencode-go": "OpenCode Go",
  synthetic: "Synthetic",
  anthropic: "the Anthropic credit",
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

// Go's monthly window, whose allowance strands at the reset. Synthetic's weekly
// meter refills continuously and can never be banked, so only Go promotes.
const GO_WINDOW_MS = 30 * 24 * 60 * 60_000;
// How much of the monthly window must be left before an under-pace pool counts
// as stranding. Earlier than this and the promotion spends 3.6x Go rates all
// month on a risk that never materialises.
const GO_STRAND_LEFT_MS = 0.3 * GO_WINDOW_MS;

// Route decisions kept per session, for `/vm`.
const TRACE_KEEP = 12;

/** Tools whose successful result means implementation has started. */
const EDIT_TOOLS = new Set(["edit", "write"]);

/** A place on a ladder: the stage (pool) and the model inside it. */
type Position = { stage: number; model: number };
type KindState = { at: Position };
type ArchitectState = {
  phase: "plan" | "build";
  at: Position;
  verdict?: boolean;
  /** The shadow re-rate at the plan→build boundary; see classifyPlan. */
  reRate?: boolean;
};

/** One route decision, as `/vm` shows it. */
type TraceEntry = {
  at: number;
  kind: string;
  reason: string;
  provider: string;
  model: string;
  notes: string[];
};

export default function (pi: ExtensionAPI) {
  const usage = createUsageReader();
  /** Per provider, set by its own limit errors; ai-usage alone lags them. */
  const blockedUntil: Record<string, number> = {};
  /** The provider a limit error stopped; its turn continues one stage down. */
  let resumeAfter: string | undefined;
  /** Sessions whose next prompt goes back to planning. */
  const replan = new Set<string>();
  /** Per session, the Anthropic credit spent, as accumulated from message usage. */
  const creditSpentBySession = new Map<string, number>();
  /** Per session, the last route decisions (`/vm` shows the tail). */
  const traces = new Map<string, TraceEntry[]>();

  /** Whether ai-usage has the provider out of quota right now. */
  const spent = (provider: string) => exhaustedWindow(usage.provider(provider)) !== undefined;

  /** The credit is the reserve: below it no kind spends Anthropic at all. */
  const creditAboveReserve = () => {
    const credit = usage.provider("anthropic")?.credit;
    return !credit || credit.remaining >= CREDIT_RESERVE_USD;
  };

  /** Why a stage cannot serve a request right now, or undefined when it can. */
  const stageWhy = (stage: Stage): string | undefined => {
    if (stage.provider === "anthropic") {
      return creditAboveReserve() ? undefined : `credit below the $${CREDIT_RESERVE_USD} reserve`;
    }
    const until = blockedUntil[stage.provider] ?? 0;
    if (Date.now() < until) return `blocked by its own limit error until ${fmtWhen(until)}`;
    const window = exhaustedWindow(usage.provider(stage.provider));
    if (window) return `out of requests until ${fmtWhen(window.resetsAt)}`;
    return undefined;
  };

  /**
   * Go's monthly window under pace with little of it left: the remaining
   * allowance can no longer be spent down in time and will strand at the
   * reset, so its stages go ahead of Synthetic's. The text explains the state
   * for `/vm`; falsy when the promotion is inactive.
   */
  const goStrandingWhy = (): string | undefined => {
    const window = usage.provider("opencode-go")?.windows.find((w) => w.label === "monthly");
    if (!window || window.pace !== "under") return undefined;
    const left = Date.parse(window.resetsAt) - Date.now();
    if (left > GO_STRAND_LEFT_MS) return undefined;
    const days = Math.max(1, Math.round(left / 86_400_000));
    return `monthly ${Math.round(window.usedPct)}% used with ~${days}d to reset, on pace to strand`;
  };

  /**
   * The order stages are tried in, as indices into the ladder: a stranding Go
   * window swaps its stage ahead of an adjacent Synthetic one, and background
   * requests hold the credit stage back to last.
   */
  const layout = (ladder: Ladder, background: boolean): number[] => {
    const order = ladder.map((_, i) => i);
    if (goStrandingWhy()) {
      for (let i = 0; i + 1 < order.length; i++) {
        if (ladder[i].provider === "synthetic" && ladder[i + 1].provider === "opencode-go") {
          [order[i], order[i + 1]] = [order[i + 1], order[i]];
        }
      }
    }
    if (background) {
      const held = order.filter((i) => ladder[i].provider === "anthropic");
      const rest = order.filter((i) => ladder[i].provider !== "anthropic");
      return [...rest, ...held];
    }
    return order;
  };

  const find = (ctx: ExtensionContext, stage: Stage, model: number) => {
    const variant = stage.variants[model];
    const found = ctx.modelRegistry.find(stage.provider, variant.id);
    if (!found) throw new Error(`${stage.provider}/${variant.id} is not in the catalog`);
    return found;
  };

  /**
   * Where to send this request: the first ready stage in `layout` order, taking
   * the model that fits the turn (a text-only one is skipped while the
   * conversation carries images). `from` is the current position for a
   * continuation, so a working model keeps its prompt cache; a fresh prompt
   * starts at the front so a recovered pool is used again. Returns the position
   * plus, for `/vm`, why each stage passed over was skipped.
   */
  const pick = async (
    ladder: Ladder,
    from: Position | undefined,
    messages: readonly Message[],
    background = false,
  ): Promise<{ at: Position; notes: string[] }> => {
    // Only the first decision waits; later ones use the last snapshot.
    if (!usage.known()) await usage.refresh();
    else void usage.refresh();
    const order = layout(ladder, background);
    const images = hasImages(messages);
    const fits = (stage: Stage, model: number) => !images || stage.variants[model].vision !== false;

    const notes: string[] = [];
    const search = (fromIdx: number): Position | undefined => {
      const sequence = [...order.slice(fromIdx), ...order.slice(0, fromIdx)];
      for (const s of sequence) {
        const stage = ladder[s];
        const why = stageWhy(stage);
        if (why !== undefined) {
          const note = `${stage.label}: ${why}`;
          if (!notes.includes(note)) notes.push(note);
          continue;
        }
        // Staying on the same model keeps the cache; otherwise the preferred one.
        const preferred = from?.stage === s && fits(stage, from.model) ? from.model : 0;
        for (const m of [preferred, ...stage.variants.keys()]) {
          if (fits(stage, m)) return { stage: s, model: m };
        }
        notes.push(`${stage.label}: no variant can read this turn's images`);
      }
      return undefined;
    };

    const startIdx = from ? Math.max(0, order.indexOf(from.stage)) : 0;
    // Down the layout first, then up it, for a pool that recovered mid-turn.
    const at = search(startIdx) ?? from ?? { stage: order[0], model: 0 };
    return { at, notes };
  };

  const toTrace = (
    ctx: ExtensionContext,
    kind: string,
    reason: string,
    stage: Stage,
    at: Position,
    notes: string[],
  ) => {
    const sid = ctx.sessionManager.getSessionId();
    const list = traces.get(sid) ?? [];
    list.push({
      at: Date.now(),
      kind,
      reason,
      provider: stage.provider,
      model: stage.variants[at.model].id,
      notes,
    });
    traces.set(sid, list.slice(-TRACE_KEEP));
  };

  /** Route within one kind's ladder, keeping `state` unless the position changes. */
  const routeKind = async <S extends object>(
    ladder: Ladder,
    kind: string,
    request: ModelRouteRequest<S>,
    ctx: ExtensionContext,
    current: Position | undefined,
    withAt: (at: Position) => S,
    preNotes: string[] = [],
  ): Promise<ModelRoute<S>> => {
    // Retries keep the failed model, so its cache and reasoning replay stay valid.
    if (request.reason === "retry" && request.failed) {
      return { model: request.failed.model, thinkingLevel: request.thinkingLevel };
    }
    // A new prompt walks the whole ladder again; anything else starts where it is.
    const fresh = request.reason === "user" || request.reason === "direct";
    const { at, notes } = await pick(
      ladder,
      fresh ? undefined : current,
      request.messages,
      request.reason === "direct",
    );
    if (current && current.stage !== at.stage) {
      notifySwitch(
        ctx,
        ladder[current.stage],
        ladder[at.stage],
        stageWhy(ladder[current.stage]) !== undefined,
      );
    }
    toTrace(ctx, kind, request.reason, ladder[at.stage], at, [...preNotes, ...notes]);
    return {
      model: find(ctx, ladder[at.stage], at.model),
      thinkingLevel: request.thinkingLevel,
      state: samePosition(current, at) ? request.state : withAt(at),
    };
  };

  /**
   * The shadow re-rate at the plan→build boundary: with the plan text in
   * state, the same complexity question that gated the prompt. A plan that
   * reads complex after a standard prompt is the misclassification the
   * prompt gate cannot see. Shadow only: the verdict is marked and
   * traced, never routed on, until it has earned a threshold on real
   * sessions. No verdict is not a signal.
   */
  const classifyPlan = async (
    ctx: ExtensionContext,
    request: ModelRouteRequest<ArchitectState>,
  ): Promise<{ complex?: boolean; note: string }> => {
    const jev = ctx.modelRegistry.findOfType("classifier", "typesafe", "jev-latest");
    if (!jev) return { note: "re-rate off: no typesafe credentials" };
    try {
      const result = await ctx.modelRegistry.classify(
        jev,
        {
          state: {
            prompt: lastUserText(request.messages).slice(0, 4_000),
            plan: planText(request.messages).slice(0, 12_000),
          },
          questions: {
            complexity: {
              type: "choice",
              instructions:
                "The finished plan for `prompt` is in `plan`. Does the plan reveal work more demanding than an ordinary feature, fix, review or question?",
              criteria: {
                standard: "The plan covers ordinary work with straightforward steps",
                complex: "The plan reveals subtle design, cross-cutting changes, or hard debugging",
              },
            },
          },
        },
        { signal: request.signal },
      );
      const answer = result.stopReason === "stop" ? result.answers.complexity : undefined;
      if (answer?.type === "choice") {
        const complex = (answer.probabilities.complex ?? 0) >= 0.5;
        return { complex, note: complex ? "re-rate: complex" : "re-rate: standard" };
      }
      return { note: `re-rate inconclusive (${result.errorMessage ?? result.stopReason})` };
    } catch (error) {
      return { note: `re-rate failed (${errorText(error)}): no verdict` };
    }
  };

  const notifySwitch = (ctx: ExtensionContext, from: Stage, to: Stage, down: boolean) => {
    if (!ctx.hasUI) return;
    ctx.ui.notify(
      down
        ? `${from.label} is used up: continuing on ${to.label}`
        : `${to.label} goes first while its window can still strand: continuing on it`,
      "info",
    );
  };

  /**
   * A phase marker in the chat: gate verdicts and transitions as they happen.
   * `warning` is for the ones worth a second look — a shadow re-rate changing
   * its mind. Subagents run without a UI.
   */
  const marker = (ctx: ExtensionContext, text: string, type: "info" | "warning" = "info") => {
    if (!ctx.hasUI) return;
    ctx.ui.notify(text, type);
  };

  /**
   * The Jev verdict for a planning entry: `false` plans on flash, anything
   * else on the planner. No verdict fails open to the planner — the gate is
   * missing credentials, a quota or a bad answer, not a signal.
   */
  const classifyPlanning = async (
    ctx: ExtensionContext,
    request: ModelRouteRequest<ArchitectState>,
  ): Promise<{ verdict?: boolean; note: string }> => {
    const jev = ctx.modelRegistry.findOfType("classifier", "typesafe", "jev-latest");
    if (!jev) return { note: "gate off: Jev not available (no typesafe credentials)" };
    try {
      const result = await ctx.modelRegistry.classify(
        jev,
        {
          state: { prompt: lastUserText(request.messages).slice(0, 16_000) },
          questions: {
            complexity: {
              type: "choice",
              instructions: "How demanding is the software engineering work requested in `prompt`?",
              criteria: {
                standard: "Ordinary features, fixes, reviews, or questions",
                complex: "Subtle design, cross-cutting changes, or hard debugging",
              },
            },
          },
        },
        { signal: request.signal },
      );
      const answer = result.stopReason === "stop" ? result.answers.complexity : undefined;
      if (answer?.type === "choice") {
        const complex = (answer.probabilities.complex ?? 0) >= 0.5;
        return { verdict: complex, note: complex ? "jev: complex" : "jev: standard" };
      }
      return {
        note: `gate inconclusive (${result.errorMessage ?? result.stopReason}): planning on the planner`,
      };
    } catch (error) {
      return { note: `gate failed (${errorText(error)}): planning on the planner` };
    }
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
        routeKind<KindState>(ladder, id, request, ctx, request.state?.at, (at) => ({ at })),
    });

  for (const kind of Object.keys(KINDS) as Kind[]) register(kind, KINDS[kind], KIND_META[kind]);

  pi.registerVirtualModel<ArchitectState>({
    provider: PROVIDER,
    id: "architect",
    name: KIND_META.architect.name,
    thinkingLevels: KIND_META.architect.thinkingLevels,
    contextWindow: KIND_META.architect.contextWindow,
    async route(request, ctx) {
      // Retries keep the failed model, so its cache and reasoning replay stay valid.
      if (request.reason === "retry" && request.failed) {
        return { model: request.failed.model, thinkingLevel: request.thinkingLevel };
      }
      // Background requests never start or continue a planning phase; they go
      // to the flash ladder in background order (credit last).
      if (request.reason === "direct") {
        const { at, notes } = await pick(FLASH, undefined, request.messages, true);
        toTrace(ctx, "architect", "direct", FLASH[at.stage], at, notes);
        return {
          model: find(ctx, FLASH[at.stage], at.model),
          thinkingLevel: request.thinkingLevel,
        };
      }
      const state = request.state;
      const sessionId = ctx.sessionManager.getSessionId();
      const startPlanning = !state || (request.reason === "user" && replan.delete(sessionId));
      if (startPlanning || (state.phase === "plan" && !editedThisTurn(request.messages))) {
        // Every entry into planning is rated: complex prompts on the planner
        // kind, standard ones on flash, no verdict on the planner.
        // The verdict persists across planning continuations in the branch state.
        const gate = startPlanning
          ? await classifyPlanning(ctx, request)
          : { verdict: state.verdict, note: "" };
        const ladder = gate.verdict === false ? FLASH : PLANNER;
        if (startPlanning) {
          marker(
            ctx,
            `architect: planning on ${gate.verdict === false ? "flash" : "the planner"} — ${gate.note}`,
          );
        }
        const at = startPlanning ? undefined : state.at;
        return routeKind(
          ladder,
          "architect",
          request,
          ctx,
          at,
          (position) => ({ phase: "plan", at: position, verdict: gate.verdict }),
          gate.note ? [gate.note] : [],
        );
      }
      // Planning made the first edit: the rest goes to the flash ladder. The
      // crossing itself re-rates the finished plan (shadow): marked in the
      // chat, kept in the trace and the branch state, never routed on.
      const crossing = state.phase === "plan";
      const at = state.phase === "build" ? state.at : undefined;
      const reRate = crossing ? await classifyPlan(ctx, request) : undefined;
      if (reRate) {
        const clause =
          reRate.complex === undefined
            ? reRate.note
            : `re-rate: ${reRate.complex ? "complex" : "standard"}` +
              (reRate.complex === state.verdict
                ? " (agrees)"
                : state.verdict === false
                  ? " (would have planned on the planner; shadow)"
                  : " (the planner could have been skipped; shadow)");
        marker(
          ctx,
          `architect: plan → build on flash — ${clause}`,
          reRate.complex !== undefined && reRate.complex !== state.verdict ? "warning" : "info",
        );
      }
      return routeKind(
        FLASH,
        "architect",
        request,
        ctx,
        at,
        (position) => ({
          phase: "build",
          at: position,
          ...(reRate?.complex !== undefined ? { reRate: reRate.complex } : {}),
        }),
        reRate ? ["planning made the first edit", reRate.note] : [],
      );
    },
  });

  pi.registerCommand("replan", {
    description: "Send the next prompt (or the given one) back to vm/architect's planning",
    handler: async (args, ctx) => {
      replan.add(ctx.sessionManager.getSessionId());
      if (args.trim()) pi.sendUserMessage(args.trim());
      else ctx.ui.notify("The next prompt goes back to planning", "info");
    },
  });

  pi.registerCommand("vm", {
    description: "The pools, the credit, and why the last routes went where they did",
    handler: async (_args, ctx) => {
      await usage.refresh();
      pi.sendMessage(
        { customType: "vm-status", content: statusLines(ctx).join("\n"), display: true },
        { deliverAs: "nextTurn" },
      );
    },
  });

  const statusLines = (ctx: ExtensionContext): string[] => {
    const credit = usage.provider("anthropic")?.credit;
    const sessionId = ctx.sessionManager.getSessionId();
    const creditLine = credit
      ? `$${credit.remaining.toFixed(2)} left, $${Math.max(0, credit.remaining - CREDIT_RESERVE_USD).toFixed(2)} above the $${CREDIT_RESERVE_USD} reserve; this session has spent $${(creditSpentBySession.get(sessionId) ?? 0).toFixed(2)} of it`
      : "unknown (ai-usage off or its key missing?)";
    const lines: string[] = [`the Anthropic credit: ${creditLine}`];
    for (const provider of usage.providers()) {
      if (provider.id === "anthropic") continue;
      lines.push(`${PROVIDER_NAME[provider.id] ?? provider.id}: ${describeWindows(provider)}`);
    }
    const stranding = goStrandingWhy();
    lines.push(
      `Go promotion: ${stranding ? `active (${stranding})` : "off (Go monthly not both late and under pace)"}`,
    );
    const tail = (traces.get(sessionId) ?? []).slice(-5);
    if (tail.length > 0) lines.push("last routes:");
    for (const entry of tail) {
      lines.push(
        `  ${fmtWhen(entry.at)} vm/${entry.kind} ${entry.reason} → ${entry.provider}/${entry.model}`,
      );
      for (const note of entry.notes) lines.push(`      ${note}`);
    }
    return lines;
  };

  const describeWindows = (provider: UsageProvider): string =>
    provider.windows
      .map((w) => `${w.label} ${Math.round(w.usedPct)}% used, resets ${fmtWhen(w.resetsAt)}`)
      .join("; ");

  const routedHere = (ctx: ExtensionContext) => ctx.model?.provider === PROVIDER;

  pi.on("message_end", async (event, ctx) => {
    const message = event.message;
    if (message.role !== "assistant") return;
    if (message.provider === "anthropic" && message.usage) {
      const sessionId = ctx.sessionManager.getSessionId();
      creditSpentBySession.set(
        sessionId,
        (creditSpentBySession.get(sessionId) ?? 0) + message.usage.cost.total,
      );
    }
    if (message.stopReason !== "error") return;
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
      ladder.some((stage) => stage.provider !== provider && stageWhy(stage) === undefined),
    );
    if (routedHere(ctx) && elsewhere) resumeAfter = provider;
  });

  pi.on("agent_settled", (event, ctx) => {
    const ended = resumeAfter;
    resumeAfter = undefined;
    if (!ended || event.aborted || !routedHere(ctx)) return;
    pi.sendMessage(
      {
        customType: "vm-router",
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

/** Localized short date-time for trace, block and reset times. */
const fmtWhen = (t: number | string) =>
  new Date(t).toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

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

/** The text of the last user message, for the classifier. */
function lastUserText(messages: readonly Message[]): string {
  const content = [...messages].reverse().find((message) => message.role === "user")?.content ?? "";
  return typeof content === "string"
    ? content
    : content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("\n");
}

/** The assistant text since the last user message: the finished plan, for the re-rate. */
function planText(messages: readonly Message[]): string {
  const lastUser = [...messages].reverse().findIndex((message) => message.role === "user");
  const sinceUser = lastUser === -1 ? messages : messages.slice(messages.length - lastUser);
  const plan = sinceUser
    .filter((message) => message.role === "assistant")
    .map((message) => {
      const content = message.content;
      return typeof content === "string"
        ? content
        : content
            .filter((block) => block.type === "text")
            .map((block) => block.text)
            .join("\n");
    })
    .join("\n");
  // An empty plan (no assistant text) says nothing; fall back to the prompt so a
  // wrong rerun of the boundary classifies the same evidence as the gate.
  return plan || lastUserText(messages);
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
