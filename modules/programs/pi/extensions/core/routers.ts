/**
 * Virtual models (see pi's docs/virtual-models.md) for the kinds in
 * ../shared/kinds.ts, plus `vm/architect`: Jev rates each planning prompt,
 * complex ones plan on deep and standard ones on flash, and the first edit hands
 * the rest to flash until `/replan`. docs/models.md has the why.
 *
 * Each subscription meters one shared pool, so a stage is a pool. A pool is out
 * while ai-usage (`ai-usage --json`) reports a used-up window, and for a while
 * after its own limit error, which pi does not retry: the extension continues
 * the interrupted turn one stage down. A Go timeout moves only that retry down.
 * No kind spends the Anthropic credit below CREDIT_RESERVE_USD, and background
 * requests (`reason: "direct"`, e.g. compaction) try it last.
 */
import { createHash } from "node:crypto";
import type { Message, Model } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  ExtensionContext,
  ModelRoute,
  ModelRouteRequest,
} from "@earendil-works/pi-coding-agent";
import { exhaustedWindow, type UsageProvider, usageReader } from "../shared/ai-usage.ts";
import { walkSpend } from "../shared/usage-ledger.ts";
import {
  type ArchitectState,
  DEEP,
  FLASH,
  KIND_META,
  KINDS,
  type KindState,
  PROVIDER,
  type Kind,
  type Ladder,
  type Stage,
} from "../shared/kinds.ts";

/** Below this the Anthropic credit is the reserve; no kind spends it. */
const CREDIT_RESERVE_USD = 20;
const PROVIDER_NAME: Record<string, string> = {
  "opencode-go": "OpenCode Go",
  synthetic: "Synthetic",
  "kimi-coding": "Kimi Code",
  anthropic: "the Anthropic credit",
};
// The providers whose own subscription limits pi lists as non-retryable.
const LIMIT_ERROR: Record<string, RegExp> = {
  "opencode-go": /GoUsageLimitError|Monthly usage limit reached|available balance/i,
  synthetic: /quota|credit|rate.?limit|429/i,
  "kimi-coding": /reached your (5-hour|weekly|monthly) usage limit|credit balance is insufficient/i,
};
// Transient failures pi retries: the retry goes one stage down, the pool stays open.
const TRANSIENT_ERROR: Record<string, RegExp> = {
  "opencode-go": /timed? ?out|timeout|overloaded|ended without|stream ended|terminated/i,
};
// How long a limit error blocks its pool on its own; ai-usage lags the error, and
// once it reports the used-up window that window's reset blocks instead.
const BLOCK_FALLBACK_MS = 10 * 60_000;
// The share of the weekly meter the router leaves unspent: a turn that spends it
// to the last drop ends in a hard 429 that no pool can cover, while a reserve
// regenerates at 2% per 202 minutes and keeps the pool usable next session.
const SYNTHETIC_RESERVE_PCT = 10;

// Route decisions kept per session, for `/vm`.
const TRACE_KEEP = 12;

/** Tools whose successful result means implementation has started. */
const EDIT_TOOLS = new Set(["edit", "write"]);

/** One custom entry per Jev verdict, to compare the gate against another classifier later. */
const JEV_ENTRY = "vm-jev";

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
  const usage = usageReader();
  /** Per provider, set by its own limit errors; ai-usage alone lags them. */
  const blockedUntil: Record<string, number> = {};
  /** The provider a limit error stopped; its turn continues one stage down. */
  let resumeAfter: string | undefined;
  /** Sessions whose next prompt goes back to planning. */
  const replan = new Set<string>();
  /** Per session, the last route decisions (`/vm` shows the tail). */
  const traces = new Map<string, TraceEntry[]>();

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
    const window = exhaustedWindow(usage.provider(stage.provider));
    if (window) {
      return window.meter
        ? `out of credits until the next top-up ${fmtWhen(window.resetsAt)}`
        : `out of requests until ${fmtWhen(window.resetsAt)}`;
    }
    const until = blockedUntil[stage.provider] ?? 0;
    if (Date.now() < until) return `blocked by its own limit error until ${fmtWhen(until)}`;
    const meter = usage.provider(stage.provider)?.windows.find((w) => w.meter);
    if (meter && 100 - meter.usedPct <= SYNTHETIC_RESERVE_PCT) {
      return `${Math.round(100 - meter.usedPct)}% credits left, under the ${SYNTHETIC_RESERVE_PCT}% reserve`;
    }
    return undefined;
  };

  /** The order stages are tried in, as ladder indices: background requests hold the credit back to last. */
  const layout = (ladder: Ladder, background: boolean): number[] => {
    const order = ladder.map((_, i) => i);
    if (!background) return order;
    const credit = (i: number) => ladder[i].provider === "anthropic";
    return [...order.filter((i) => !credit(i)), ...order.filter(credit)];
  };

  const find = (ctx: ExtensionContext, stage: Stage) => {
    const found = ctx.modelRegistry.find(stage.provider, stage.id);
    if (!found) throw new Error(`${stage.provider}/${stage.id} is not in the catalog`);
    return found;
  };

  /**
   * The first ready stage in `layout` order, from `from` for a continuation so a
   * working model keeps its prompt cache; a fresh prompt starts at the front so
   * a recovered pool is used again. `at` is undefined when no pool can serve;
   * `notes` say, for `/vm`, why each stage passed over was skipped.
   */
  const pick = async (
    ladder: Ladder,
    from: number | undefined,
    background: boolean,
  ): Promise<{ at?: number; notes: string[] }> => {
    // Only the first decision waits; later ones use the last snapshot.
    if (!usage.known()) await usage.refresh();
    else void usage.refresh();
    const order = layout(ladder, background);
    const start = from === undefined ? 0 : Math.max(0, order.indexOf(from));
    const notes: string[] = [];
    // Down the layout first, then up it, for a pool that recovered mid-turn.
    for (const s of [...order.slice(start), ...order.slice(0, start)]) {
      const why = stageWhy(ladder[s]);
      if (why === undefined) return { at: s, notes };
      notes.push(`${ladder[s].label}: ${why}`);
    }
    return { notes };
  };

  const toTrace = (
    ctx: ExtensionContext,
    kind: string,
    reason: string,
    stage: Stage,
    notes: string[],
  ) => {
    const sid = ctx.sessionManager.getSessionId();
    const list = traces.get(sid) ?? [];
    list.push({ at: Date.now(), kind, reason, provider: stage.provider, model: stage.id, notes });
    traces.set(sid, list.slice(-TRACE_KEEP));
  };

  /**
   * A retry keeps the failed model, so its cache and reasoning replay stay valid,
   * unless that model's pool failed transiently: then this retry alone goes to
   * the next ready stage. Undefined when routing itself failed (no `failed`).
   */
  const routeRetry = (
    ladder: Ladder,
    kind: string,
    request: ModelRouteRequest<unknown>,
    ctx: ExtensionContext,
  ): ModelRoute<never> | undefined => {
    const failed = request.failed;
    if (!failed) return undefined;
    const keep = { model: failed.model, thinkingLevel: request.thinkingLevel };
    const error = failed.message.errorMessage ?? "";
    if (!TRANSIENT_ERROR[failed.model.provider]?.test(error)) return keep;
    const index = ladder.findIndex((s) => sameModel(s, failed.model));
    const next = ladder.findIndex((s, i) => i > index && stageWhy(s) === undefined);
    if (index === -1 || next === -1) return keep;
    toTrace(ctx, kind, "retry", ladder[next], [
      `${ladder[index].label}: ${oneLine(error)} (this retry only)`,
    ]);
    return { model: find(ctx, ladder[next]), thinkingLevel: request.thinkingLevel };
  };

  /** Route within one ladder, keeping `state` unless the stage changes. */
  const routeKind = async <S extends object>(
    ladder: Ladder,
    kind: string,
    request: ModelRouteRequest<S>,
    ctx: ExtensionContext,
    current: number | undefined,
    withAt: (at: number) => S,
    preNotes: string[] = [],
  ): Promise<ModelRoute<S>> => {
    if (request.reason === "retry") {
      const retry = routeRetry(ladder, kind, request, ctx);
      if (retry) return retry;
    }
    // A new prompt walks the whole ladder again; anything else starts where it is.
    const fresh = request.reason === "user" || request.reason === "direct";
    const { at, notes } = await pick(
      ladder,
      fresh ? undefined : current,
      request.reason === "direct",
    );
    if (at === undefined) {
      throw new Error(`vm/${kind}: no pool can serve this request (${notes.join("; ")})`);
    }
    if (current !== undefined && current !== at && ladder[current] && stageWhy(ladder[current])) {
      notifySwitch(ctx, ladder[current], ladder[at]);
    }
    toTrace(ctx, kind, request.reason, ladder[at], [...preNotes, ...notes]);
    return {
      model: find(ctx, ladder[at]),
      thinkingLevel: request.thinkingLevel,
      state: current === at ? request.state : withAt(at),
    };
  };

  const notifySwitch = (ctx: ExtensionContext, from: Stage, to: Stage) => {
    if (!ctx.hasUI) return;
    ctx.ui.notify(`${from.label} is used up: continuing on ${to.label}`, "info");
  };

  /** A phase marker in the chat; subagents run without a UI. */
  const marker = (ctx: ExtensionContext, text: string) => {
    if (!ctx.hasUI) return;
    ctx.ui.notify(text, "info");
  };

  /**
   * The Jev verdict for a planning entry: `false` plans on flash, anything
   * else on deep. No verdict fails open to deep — the gate is missing
   * credentials, a quota or a bad answer, not a signal.
   */
  const classifyPlanning = async (
    ctx: ExtensionContext,
    request: ModelRouteRequest<ArchitectState>,
    prompt: string,
  ): Promise<{ verdict?: boolean; note: string }> => {
    const jev = ctx.modelRegistry.findOfType("classifier", "typesafe", "jev-latest");
    if (!jev) return { note: "gate off: Jev not available (no typesafe credentials)" };
    try {
      const result = await ctx.modelRegistry.classify(
        jev,
        {
          state: { prompt: prompt.slice(0, 16_000) },
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
        note: `gate inconclusive (${result.errorMessage ?? result.stopReason}): planning on deep`,
      };
    } catch (error) {
      return { note: `gate failed (${errorText(error)}): planning on deep` };
    }
  };

  const recordVerdict = (prompt: string, verdict: boolean | undefined, latencyMs: number) => {
    try {
      pi.appendEntry(JEV_ENTRY, {
        promptHash: createHash("sha256").update(prompt).digest("hex").slice(0, 16),
        verdict: verdict === undefined ? null : verdict ? "complex" : "standard",
        latencyMs,
        ladder: verdict === false ? "flash" : "deep",
      });
    } catch {
      // No session to write to (shutting down); the verdict goes unrecorded.
    }
  };

  for (const kind of Object.keys(KINDS) as Kind[]) {
    const meta = KIND_META[kind];
    pi.registerVirtualModel<KindState>({
      provider: PROVIDER,
      id: kind,
      name: meta.name,
      thinkingLevels: meta.thinkingLevels,
      contextWindow: meta.contextWindow,
      route: (request, ctx) =>
        routeKind<KindState>(KINDS[kind], kind, request, ctx, stageOf(request.state), (at) => ({
          at,
        })),
    });
  }

  pi.registerVirtualModel<ArchitectState>({
    provider: PROVIDER,
    id: "architect",
    name: KIND_META.architect.name,
    thinkingLevels: KIND_META.architect.thinkingLevels,
    contextWindow: KIND_META.architect.contextWindow,
    async route(request, ctx) {
      // Background requests never start or continue a planning phase; pi ignores their state.
      if (request.reason === "direct") {
        return routeKind(FLASH, "architect", request, ctx, undefined, () => ({}) as ArchitectState);
      }
      const state = request.state;
      const sessionId = ctx.sessionManager.getSessionId();
      // Consumed on every prompt, so a /replan never outlives the prompt it was for.
      const replanned = request.reason === "user" && replan.delete(sessionId);
      const startPlanning = !state || replanned;
      if (startPlanning || (state.phase === "plan" && !editedThisTurn(request.messages))) {
        let gate: { verdict?: boolean; note: string } = { verdict: state?.verdict, note: "" };
        if (startPlanning && request.reason !== "retry") {
          const prompt = lastUserText(request.messages);
          const started = Date.now();
          gate = await classifyPlanning(ctx, request, prompt);
          recordVerdict(prompt, gate.verdict, Date.now() - started);
          marker(
            ctx,
            `architect: planning on ${gate.verdict === false ? "flash" : "deep"} — ${gate.note}`,
          );
        }
        return routeKind(
          gate.verdict === false ? FLASH : DEEP,
          "architect",
          request,
          ctx,
          startPlanning ? undefined : stageOf(state),
          (at) => ({ phase: "plan", at, verdict: gate.verdict }),
          gate.note ? [gate.note] : [],
        );
      }
      const crossing = state.phase === "plan";
      if (crossing) marker(ctx, "architect: plan → build on flash");
      return routeKind(
        FLASH,
        "architect",
        request,
        ctx,
        crossing ? undefined : stageOf(state),
        (at) => ({ phase: "build", at }),
        crossing ? ["planning made the first edit"] : [],
      );
    },
  });

  pi.registerCommand("replan", {
    description: "Send the next prompt (or the given one) back to vm/architect's planning",
    handler: async (args, ctx) => {
      // Only vm/architect consumes the entry; on any other model it would wait for a later switch.
      if (ctx.model?.provider !== PROVIDER || ctx.model.id !== "architect") {
        ctx.ui.notify("/replan only applies while vm/architect is the model", "warning");
        return;
      }
      replan.add(ctx.sessionManager.getSessionId());
      const prompt = args.trim();
      if (prompt) pi.sendUserMessage(prompt, ctx.isIdle() ? undefined : { deliverAs: "followUp" });
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
    let spent = 0;
    walkSpend(ctx.sessionManager.getEntries(), (_entry, items) => {
      for (const item of items)
        if (item.provider === "anthropic") spent += item.usage.cost?.total ?? 0;
    });
    const creditLine = credit
      ? `$${credit.remaining.toFixed(2)} left, $${Math.max(0, credit.remaining - CREDIT_RESERVE_USD).toFixed(2)} above the $${CREDIT_RESERVE_USD} reserve; this session has spent $${spent.toFixed(2)} of it`
      : "unknown (ai-usage off or its key missing?)";
    const lines: string[] = [`the Anthropic credit: ${creditLine}`];
    for (const provider of usage.providers()) {
      if (provider.id === "anthropic") continue;
      const until = blockedUntil[provider.id] ?? 0;
      const blocked =
        Date.now() < until ? `; blocked by a limit error until ${fmtWhen(until)}` : "";
      lines.push(
        `${PROVIDER_NAME[provider.id] ?? provider.id}: ${describeWindows(provider)}${blocked}`,
      );
    }
    const tail = (traces.get(ctx.sessionManager.getSessionId()) ?? []).slice(-5);
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
      .map(
        (w) =>
          `${w.label} ${Math.round(w.usedPct)}% used, ${w.meter ? "next top-up" : "resets"} ${fmtWhen(w.resetsAt)}`,
      )
      .join("; ");

  const routedHere = (ctx: ExtensionContext) => ctx.model?.provider === PROVIDER;

  pi.on("message_end", (event, ctx) => {
    const message = event.message;
    if (message.role !== "assistant" || message.stopReason !== "error") return;
    const provider = message.provider;
    if (!LIMIT_ERROR[provider]?.test(message.errorMessage ?? "")) return;
    blockedUntil[provider] = Date.now() + BLOCK_FALLBACK_MS;
    // The snapshot that sent the request predates the error; once ai-usage
    // reports the used-up window, stageWhy blocks until its reset.
    void usage.refresh({ force: true });
    // Continue the turn only if that block left another pool to continue on.
    const elsewhere = Object.values(KINDS).some((ladder) =>
      ladder.some((stage) => stage.provider !== provider && stageWhy(stage) === undefined),
    );
    if (routedHere(ctx) && elsewhere) resumeAfter = provider;
  });

  // Continuing before the run settles keeps settle listeners from seeing it finish and restart.
  pi.on("agent_before_settle", (event, ctx) => {
    const ended = resumeAfter;
    resumeAfter = undefined;
    if (!ended || event.outcome === "aborted" || !routedHere(ctx)) return;
    return {
      entries: [
        ...event.entries,
        {
          type: "custom_message",
          customType: "vm-router",
          content: `${PROVIDER_NAME[ended] ?? ended} ran out of quota mid-turn. Continue where you left off.`,
          display: true,
        },
      ],
      continue: true,
    };
  });

  // An aborted run skips agent_before_settle; the flag must not carry into the next one.
  pi.on("agent_settled", () => {
    resumeAfter = undefined;
  });
}

/** The stage index in stored state; sessions from before one model per stage stored an object. */
const stageOf = (state: { at?: unknown } | undefined) =>
  typeof state?.at === "number" ? state.at : undefined;

const sameModel = (stage: Stage, model: Model<any>) =>
  stage.provider === model.provider && stage.id === model.id;

/** Localized short date-time for trace, block and reset times. */
const fmtWhen = (t: number | string) =>
  new Date(t).toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

const oneLine = (text: string) => text.replace(/\s+/g, " ").trim().slice(0, 120);

/** The text of the last user message, for the classifier. */
function lastUserText(messages: readonly Message[]): string {
  const content = [...messages].reverse().find((message) => message.role === "user")?.content ?? "";
  return typeof content === "string"
    ? content
    : content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("\n");
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
