/**
 * You should know: a note above the editor when a side agent spots something
 * you probably missed. A port of Claude Code's cc-plugin-you-should-know.
 *
 * The scheduling rule and every constant here were read out of the 2.1.308
 * binary rather than taken from a port; the extraction and its diffs live in
 * `~/.local/share/agents/you-should-know/reference`.
 *
 * - A check runs at the 6th step of a turn, again at the 12th, 18th …, at most
 *   once per turn, and never while a note is showing. Turns shorter than six
 *   steps never check: that is the mod's "longer tasks only" rule.
 * - The side request replays the main request's provider payload with one user
 *   message appended, so the conversation prefix is a prompt-cache read. A
 *   rebuilt request pays full input price on every token, which at DeepSeek's
 *   cache-read rate is the difference between ~$0.0006 and ~$0.015 per check
 *   at 100k tokens.
 * - A note survives 2 user prompts; then it is cleared and counts as ignored.
 *   Two ignored notes are free, after which the checker skips 1, 2, 4, 8, 16
 *   checks. Dismissing a note counts as answering it and resets that.
 * - Notes are shown to you only; they never enter the model's context. The
 *   Claude Code mod's "Learn more" page, its survey rows and its telemetry are
 *   not ported, and the reply asks for two fields instead of four.
 */
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { Message, Model } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { wrapTextWithAnsi } from "@earendil-works/pi-tui";

// Read from the mod's own export map; see the reference notes for the extraction.
const CHECK_EVERY = 6; // CHECK_EVERY: the step of a turn that may check
const CLEAR_AFTER_PROMPTS = 2; // CLEAR_AFTER_PROMPTS: unanswered notes expire
const FREE_IGNORES = 2; // ignores before backoff starts
const LOOKS_TO_SKIP_MAX = 16; // backoff cap
const SEEN_MAX = 50; // SEEN_MAX
const CHECKS_KEPT = 3; // CHECKS_KEPT: debug rows kept for /ysk

const MAX_LINE_WIDTH = 240;
const MAX_REPLY_TOKENS = 512;
const REQUEST_TIMEOUT_MS = 45_000;

const MODEL = process.env.PI_YSK_MODEL?.trim() || "";
// Providers whose requests would compete with the main turn for one GPU.
const SKIP_PROVIDERS = (process.env.PI_YSK_SKIP_PROVIDERS ?? "")
  .split(",")
  .map((name) => name.trim())
  .filter((name) => name !== "");

const AGENT_DIR = process.env.PI_CODING_AGENT_DIR?.trim() || join(homedir(), ".pi", "agent");
const STATE_DIR = join(AGENT_DIR, "you-should-know");
const STATE_FILE = join(STATE_DIR, "state.json");
const CHECKS_FILE = join(STATE_DIR, "checks.jsonl");
const WIDGET = "you-should-know";
const HERE = dirname(fileURLToPath(import.meta.url));

const PROMPT = (() => {
  try {
    return readFileSync(join(HERE, "you-should-know", "detect.md"), "utf8");
  } catch {
    return "";
  }
})();

type Tag = "You should know" | "Heads up";
type Offer = { line: string; tag: Tag; prompts: number };
type State = { enabled: boolean; seen: string[]; typedPast: number; looksToSkip: number };
type Check = {
  at: string;
  step: number;
  outcome: string;
  ms: number;
  model?: string;
  aligned?: Record<string, unknown>;
  input?: number;
  cacheRead?: number;
  cacheWrite?: number;
  cost?: number;
  error?: string;
};
type Parsed = { kind: "none" } | { kind: "unparsable" } | { kind: "line"; line: string; tag: Tag };

const backoff = (ignored: number) =>
  ignored <= FREE_IGNORES ? 0 : Math.min(LOOKS_TO_SKIP_MAX, 2 ** (ignored - FREE_IGNORES - 1));

const normalize = (line: string) =>
  line.toLowerCase().replace(/\.+$/, "").replace(/\s+/g, " ").trim();

const listed = (lines: string[]) =>
  lines.length > 0 ? lines.map((line) => `- ${line}`).join("\n") : "(nothing yet)";

/** The mod's `parseProposedLine`, minus its explanation and markdown handling. */
function parse(text: string): Parsed {
  const lines = text
    .split("\n")
    .map((line) => line.replace(/^[\s>*_`"'\u201c\u201d\u2018\u2019-]+/, "").trim());
  const at = lines.findIndex((line) => /^learn\s*:/i.test(line));
  if (at === -1) return { kind: "unparsable" };
  let line = lines[at]
    .replace(/^learn\s*:\s*/i, "")
    .replace(/[*_`\s]+$/, "")
    .trim();
  if (line === "" || /^none\b/i.test(line)) return { kind: "none" };
  if (!/[.!?]["')\]]?$/.test(line)) line += ".";
  if (line.length > MAX_LINE_WIDTH) return { kind: "unparsable" };
  const tagLine = lines.find((candidate) => /^tag\s*:/i.test(candidate));
  return {
    kind: "line",
    line,
    tag: tagLine && /heads[\s-]*up/i.test(tagLine) ? "Heads up" : "You should know",
  };
}

function textOf(message: { content: readonly unknown[] }): string {
  return message.content
    .filter(
      (block): block is { type: "text"; text: string } =>
        typeof block === "object" &&
        block !== null &&
        (block as { type?: unknown }).type === "text" &&
        typeof (block as { text?: unknown }).text === "string",
    )
    .map((block) => block.text)
    .join("\n")
    .trim();
}

/** Two provider messages are the same conversation step if they differ only in cache markers. */
const sameMessage = (a: unknown, b: unknown) =>
  JSON.stringify(a, (key, value) => (key === "cache_control" ? undefined : value)) ===
  JSON.stringify(b, (key, value) => (key === "cache_control" ? undefined : value));

export default function (pi: ExtensionAPI) {
  let state: State = { enabled: true, seen: [], typedPast: 0, looksToSkip: 0 };
  let offer: Offer | undefined;
  let inFlight: AbortController | undefined;
  let offeredTurn: string | undefined;
  let promptCounter = 0;
  let runId = 0;
  let checks = 0;
  let warnedModel = false;
  const recent: Check[] = [];

  // The exact payload the main request sent, so the fork can reuse its prefix.
  let mainPayload: Record<string, unknown> | undefined;
  let aligned: Record<string, unknown> | undefined;
  const forkPayloads = new WeakSet<object>();

  function loadState() {
    try {
      const raw = JSON.parse(readFileSync(STATE_FILE, "utf8")) as Partial<State>;
      state = {
        enabled: raw.enabled !== false,
        seen: Array.isArray(raw.seen)
          ? raw.seen.filter((line): line is string => typeof line === "string").slice(-SEEN_MAX)
          : [],
        typedPast: Number.isSafeInteger(raw.typedPast) ? (raw.typedPast as number) : 0,
        looksToSkip: Number.isSafeInteger(raw.looksToSkip) ? (raw.looksToSkip as number) : 0,
      };
    } catch {
      state = { enabled: true, seen: [], typedPast: 0, looksToSkip: 0 };
    }
  }

  function saveState() {
    try {
      mkdirSync(STATE_DIR, { recursive: true });
      const scratch = `${STATE_FILE}.${process.pid}.tmp`;
      writeFileSync(scratch, JSON.stringify(state, null, 2));
      renameSync(scratch, STATE_FILE);
    } catch {}
  }

  function record(check: Check) {
    recent.push(check);
    if (recent.length > CHECKS_KEPT) recent.shift();
    try {
      mkdirSync(STATE_DIR, { recursive: true });
      writeFileSync(CHECKS_FILE, `${JSON.stringify(check)}\n`, { flag: "a" });
    } catch {}
  }

  function draw(ctx: ExtensionContext) {
    if (ctx.mode !== "tui") return;
    if (!offer || !state.enabled) {
      ctx.ui.setWidget(WIDGET, undefined);
      return;
    }
    const { line, tag } = offer;
    ctx.ui.setWidget(WIDGET, (_tui, theme) => ({
      render: (width: number) =>
        wrapTextWithAnsi(
          `${theme.fg("accent", "\u2726")} ${theme.fg("accent", theme.bold(tag))}${theme.fg("dim", " \u00b7 ")}${line}`,
          width,
        ),
      invalidate: () => {},
    }));
  }

  /** Answering, or ignoring, closes the note and sets the next backoff. */
  function closeOffer(ctx: ExtensionContext, how: "answered" | "ignored") {
    if (!offer) return;
    if (how === "ignored") {
      state.typedPast += 1;
      state.looksToSkip = backoff(state.typedPast);
    } else {
      state.typedPast = 0;
      state.looksToSkip = 0;
    }
    saveState();
    offer = undefined;
    draw(ctx);
  }

  function pickModel(ctx: ExtensionContext): Model<string> | undefined {
    if (MODEL === "") return ctx.model;
    const slash = MODEL.indexOf("/");
    const found = ctx.modelRegistry.find(MODEL.slice(0, slash), MODEL.slice(slash + 1));
    if (found) return found;
    if (!warnedModel && ctx.hasUI) {
      warnedModel = true;
      ctx.ui.notify(`you-should-know: PI_YSK_MODEL=${MODEL} is not a known model`, "error");
    }
    return undefined;
  }

  /**
   * Sends the main request back with one message appended. Everything before the
   * fork's own tail stays byte for byte what the provider cached, cache markers
   * included; only the tail is paid at the input rate.
   */
  function align(payload: unknown): unknown {
    if (payload !== null && typeof payload === "object") forkPayloads.add(payload);
    const main = mainPayload;
    if (!main || payload === null || typeof payload !== "object") return undefined;
    const fork = payload as Record<string, unknown>;
    if (main.model !== fork.model) {
      aligned = { why: "model differs" };
      return undefined;
    }
    const mainMessages = main.messages;
    const forkMessages = fork.messages;
    if (!Array.isArray(mainMessages) || !Array.isArray(forkMessages)) {
      aligned = { why: "no message list" };
      return undefined;
    }
    let shared = 0;
    while (
      shared < mainMessages.length &&
      shared < forkMessages.length &&
      sameMessage(mainMessages[shared], forkMessages[shared])
    ) {
      shared += 1;
    }
    if (shared === 0) {
      aligned = { why: "nothing shared" };
      return undefined;
    }
    aligned = { main: mainMessages.length, fork: forkMessages.length, shared };
    return {
      ...main,
      stream: fork.stream,
      messages: [...mainMessages.slice(0, shared), ...forkMessages.slice(shared)],
    };
  }

  async function check(ctx: ExtensionContext, step: number, llmMessages: Message[], run: number) {
    const abort = new AbortController();
    inFlight = abort;
    const atPrompt = promptCounter;
    const started = Date.now();
    const model = pickModel(ctx);
    let outcome = "error";
    let detail: Partial<Check> = {};

    try {
      if (!model) {
        outcome = "no_model";
        return;
      }
      if (SKIP_PROVIDERS.includes(model.provider)) {
        outcome = "skipped_provider";
        return;
      }
      const sameAsMain =
        ctx.model !== undefined &&
        ctx.model.provider === model.provider &&
        ctx.model.id === model.id;
      aligned = undefined;
      const messages: Message[] = [
        ...llmMessages,
        {
          role: "user",
          content: [{ type: "text", text: PROMPT.replace("{{SEEN}}", listed(state.seen)) }],
          timestamp: Date.now(),
        },
      ];
      const response = await ctx.modelRegistry
        .streamSimple(
          model,
          {
            messages,
            ...(llmMessages[0]?.role === "system" ? {} : { systemPrompt: ctx.getSystemPrompt() }),
          },
          {
            signal: abort.signal,
            sessionId: ctx.sessionManager.getSessionId(),
            temperature: 0,
            // These three only reach a routed model: an aligned request keeps the
            // main payload's max_tokens and thinking, which the prompt cache is
            // keyed on.
            maxTokens: MAX_REPLY_TOKENS,
            cacheRetention: "short",
            timeoutMs: REQUEST_TIMEOUT_MS,
            onPayload: sameAsMain
              ? align
              : (payload: unknown) => {
                  if (payload !== null && typeof payload === "object") forkPayloads.add(payload);
                  return undefined;
                },
          },
        )
        .result();

      detail = {
        model: `${model.provider}/${model.id}`,
        aligned,
        input: response.usage.input,
        cacheRead: response.usage.cacheRead,
        cacheWrite: response.usage.cacheWrite,
        cost: response.usage.cost.total,
      };
      if (abort.signal.aborted || response.stopReason === "aborted") outcome = "aborted";
      else if (response.stopReason === "error") {
        outcome = "error";
        detail.error = response.errorMessage;
      } else {
        const parsed = parse(textOf(response));
        if (parsed.kind === "none") outcome = "none";
        else if (parsed.kind === "unparsable") outcome = "unparsable";
        else if (state.seen.some((line) => normalize(line) === normalize(parsed.line)))
          outcome = "deduped";
        else if (run !== runId || promptCounter !== atPrompt) outcome = "stale";
        else {
          outcome = "shown";
          state.seen = [...state.seen, parsed.line].slice(-SEEN_MAX);
          saveState();
          offer = { line: parsed.line, tag: parsed.tag, prompts: 0 };
          draw(ctx);
        }
      }
    } catch (error) {
      outcome = abort.signal.aborted ? "aborted" : "error";
      detail.error = error instanceof Error ? error.message : String(error);
    } finally {
      if (inFlight === abort) inFlight = undefined;
      const elapsed = Date.now() - started;
      if (run === runId) {
        checks += 1;
        record({ at: new Date().toISOString(), step, outcome, ms: elapsed, ...detail });
      }
    }
  }

  pi.on("session_start", (_event, ctx) => {
    runId += 1;
    loadState();
    offer = undefined;
    offeredTurn = undefined;
    promptCounter = 0;
    checks = 0;
    recent.length = 0;
    mainPayload = undefined;
    inFlight?.abort();
    inFlight = undefined;
    if (PROMPT === "" && ctx.hasUI)
      ctx.ui.notify("you-should-know: detect.md is missing, checks are off", "error");
    draw(ctx);
  });

  pi.on("session_shutdown", () => {
    runId += 1;
    inFlight?.abort();
    inFlight = undefined;
  });

  pi.on("before_provider_request", (event, ctx) => {
    const payload = event.payload;
    if (payload === null || typeof payload !== "object" || forkPayloads.has(payload)) return;
    // Another extension's nested call runs while the agent is idle and carries its
    // own system prompt; aligning a check to it would send the wrong conversation.
    if (ctx.isIdle()) return;
    mainPayload = payload as Record<string, unknown>;
  });

  pi.on("agent_start", () => {
    offeredTurn = undefined;
  });

  pi.on("input", (event, ctx) => {
    if (event.source === "extension") return;
    if (event.text.trimStart().startsWith("/")) return;
    promptCounter += 1;
    if (!offer) return;
    offer.prompts += 1;
    if (offer.prompts < CLEAR_AFTER_PROMPTS) return;
    record({ at: new Date().toISOString(), step: -1, outcome: "ignored", ms: 0 });
    closeOffer(ctx, "ignored");
  });

  pi.on("turn_end", (event, ctx) => {
    if (PROMPT === "" || !state.enabled || ctx.mode !== "tui") return;
    if (!(event.turnIndex > 0 && event.turnIndex % CHECK_EVERY === 0)) return;
    const turn = `${promptCounter}:${event.turnIndex}`;
    if (offeredTurn === turn || offer || inFlight) return;
    const skip = Math.min(LOOKS_TO_SKIP_MAX, state.looksToSkip);
    if (skip > 0) {
      state.looksToSkip = skip - 1;
      saveState();
      record({ at: new Date().toISOString(), step: event.turnIndex, outcome: "skipped", ms: 0 });
      return;
    }
    offeredTurn = turn;
    void check(ctx, event.turnIndex, event.context.llmMessages, runId);
  });

  pi.registerShortcut("alt+x", {
    description: "You should know: dismiss the note",
    handler: (ctx) => {
      if (!offer) return;
      record({ at: new Date().toISOString(), step: -1, outcome: "dismissed", ms: 0 });
      closeOffer(ctx, "answered");
    },
  });

  pi.registerCommand("ysk", {
    description: "You should know: status, on, off, or dismiss the note",
    handler: async (args, ctx) => {
      const word = args.trim().toLowerCase();
      if (word === "on" || word === "off") {
        state.enabled = word === "on";
        if (!state.enabled) offer = undefined;
        saveState();
        draw(ctx);
        ctx.ui.notify(`You should know: ${state.enabled ? "on" : "off"}`, "info");
        return;
      }
      if (word === "dismiss") {
        if (!offer) {
          ctx.ui.notify("You should know: no note showing", "info");
          return;
        }
        record({ at: new Date().toISOString(), step: -1, outcome: "dismissed", ms: 0 });
        closeOffer(ctx, "answered");
        return;
      }
      const last = recent.filter((check) => check.step >= 0).at(-1);
      const fork = MODEL === "" ? `${ctx.model?.provider ?? "?"}/${ctx.model?.id ?? "?"}` : MODEL;
      const parts = [
        `You should know: ${state.enabled ? "on" : "off"}`,
        `${checks} checks`,
        offer ? "1 note showing" : "no note",
        `fork ${fork}`,
        `skip ${state.looksToSkip}`,
        `seen ${state.seen.length}`,
        last
          ? `last ${last.outcome} in ${last.ms}ms, cache ${last.cacheRead ?? 0} read / ${last.input ?? 0} new, $${(last.cost ?? 0).toFixed(5)}`
          : "no check yet",
      ];
      ctx.ui.notify(parts.join(" \u00b7 "), "info");
    },
  });
}
