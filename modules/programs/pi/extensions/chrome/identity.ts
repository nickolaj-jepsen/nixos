/**
 * Which pi am I looking at: the terminal title, the editor's top border, and
 * `/header`.
 *
 * The title is the only surface visible from the niri overview, so it stays
 * terse: task label, directory, age, and a state word only when the session
 * wants you. The border row is the persistent one inside pi: the label, which a
 * click relabels, pi's scroll hint, the state word and the measurements. pi's
 * working spinner sits in front of the label, and a retry, compaction or branch
 * summary takes its place. `/header` shows the details and the resume command.
 * The label is deterministic until you ask for a model one (alt+r or a click),
 * plus a refresh at each compaction boundary, which bounds the cost of a
 * feature that only has to help you pick a window.
 *
 * The border belongs to the editor; the wrapper in `editor.ts` calls `drawTop`
 * for the border row. Until you run `/name`, the session name follows the latest
 * model or manual label, so `/resume` shows something useful.
 */
import { basename } from "node:path";
import {
  copyToClipboard,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { setAutoName } from "../lib/auto-name.ts";
import {
  catalogModel,
  firstRequest,
  NAME_MODEL,
  oneLine,
  requests,
  stripRequest,
  touchedFiles,
} from "../lib/naming.ts";
import { recordSideCall } from "../lib/usage-ledger.ts";
import { trackUserWait, waitingOnUser } from "../lib/user-wait.ts";
import { shortPath } from "./format.ts";
import type { BorderStatus } from "./editor.ts";
import type { Region } from "./layout.ts";
import type { Segment } from "./measurements.ts";
import type { ChromeState } from "./state.ts";

// Hover id of the top-border label.
const LABEL_ID = "label";

type Phase = "working" | "idle" | "failed";
type Source = "name" | "prompt" | "cwd" | "model" | "manual";

type Label = {
  text: string;
  source: Source;
  at: number;
  calls: number;
  costUsd: number;
  /** The session name this extension last wrote; any other name is the user's `/name`. */
  autoName?: string;
};

const CUSTOM_TYPE = "identity_label";
const SHORTCUT = "alt+r";
const TICK_MS = 60_000;
// Worst case for a whole session; a relabel is a few hundred tokens, so this is
// less a budget than a guard against a click loop.
const CALL_CAP = 20;
const MAX_LABEL_CHARS = 40;
// Below this the label stops being the point of the row, so shed the detail first.
const MIN_LABEL_ROOM = 14;
// Roughly 1.5k tokens: prompts say what you want, touched files say what the
// agent is actually on, and neither grows with tool output.
const PROMPT_CHARS = 300;
const RECENT_PROMPTS = 5;
const TOUCHED_FILES = 6;

const SYSTEM = `You name a coding session so its owner can pick the right terminal window from a list.
Reply with 2-6 lowercase words. No punctuation, no quotes, no "session", no trailing period.
Use the user's own words and concrete nouns from the file names. Name the work, not the fact that you agreed to something.`;

// Sub-agent widgets already own `●`, `○`, `⟳` and `▸`, so states that need you
// are words and "working" is either pi's spinner or a frozen frame of one.
const WORK_GLYPH = "⠿";
const stateWord = (phase: Phase, waiting: boolean) =>
  waiting ? "waiting" : phase === "failed" ? "failed" : "";

const cleanLabel = (raw: string) => {
  const first = oneLine(raw).replace(/^(label|session|task)\s*:\s*/i, "");
  const unquoted = first.replace(/^["'`]+|["'`.,;:]+$/g, "");
  if (unquoted.length <= MAX_LABEL_CHARS) return unquoted;
  const cut = unquoted.slice(0, MAX_LABEL_CHARS);
  const lastSpace = cut.lastIndexOf(" ");
  return `${(lastSpace > 20 ? cut.slice(0, lastSpace) : cut).trim()}…`;
};

const formatCost = (usd: number) => (usd === 0 ? "$0" : `$${usd.toFixed(4)}`);

const formatAge = (ms: number) => {
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 48 ? `${hours}h` : `${Math.floor(hours / 24)}d`;
};

export const createIdentity = (pi: ExtensionAPI, state: ChromeState) => {
  let timer: ReturnType<typeof setInterval> | undefined;
  let cwd = process.cwd();
  let phase: Phase = "idle";
  let waited = false;
  let since = Date.now();
  let busy = false;
  // Aborted at session_shutdown, after which every ctx and pi call throws.
  let inflight: AbortController | undefined;
  let paintedTitle = "";
  let repaintTimer: ReturnType<typeof setTimeout> | undefined;
  let warnedModel = false;
  let label: Label | undefined;
  // Derived labels improve as a session goes on, so they are cached against the
  // branch leaf that produced them rather than persisted.
  let derivedCache: { leaf: string | null; text: string; source: Source } | undefined;

  const sessionId = () => state.ctx?.sessionManager.getSessionId() ?? "";
  const shortId = () => sessionId().slice(0, 8);

  const persist = () => {
    if (!label) return;
    pi.appendEntry<Label>(CUSTOM_TYPE, label);
  };

  /**
   * A session name we did not write is the user's choice through `/name`, and
   * it outranks anything this extension would generate.
   */
  const explicitName = () => {
    const name = pi.getSessionName();
    return name && name !== label?.autoName ? name : undefined;
  };

  /**
   * Stores a model or manual label and, unless the user named the session,
   * renames it to match: `/resume` lists sessions by name, the one place the
   * label helps before the window is even open.
   */
  const adopt = (next: Omit<Label, "autoName">) => {
    const owned = explicitName() !== undefined;
    label = { ...next, autoName: owned ? label?.autoName : next.text };
    if (owned) return;
    setAutoName(sessionId(), next.text);
    if (pi.getSessionName() !== next.text) pi.setSessionName(next.text);
  };

  const derive = (ctx: ExtensionContext): { text: string; source: Source } => {
    const leaf = ctx.sessionManager.getLeafId();
    if (derivedCache?.leaf === leaf) return derivedCache;
    let prompt = firstRequest(ctx) ?? "";
    derivedCache = prompt
      ? { leaf, text: cleanLabel(stripRequest(prompt)), source: "prompt" }
      : { leaf, text: basename(ctx.cwd) || ctx.cwd, source: "cwd" };
    return derivedCache;
  };

  const currentLabel = (ctx: ExtensionContext): { text: string; source: Source } => {
    const name = explicitName();
    if (name) return { text: name, source: "name" };
    if (label) return { text: label.text, source: label.source };
    return derive(ctx);
  };

  const renderTitle = (ctx: ExtensionContext) => {
    const { text } = currentLabel(ctx);
    const age = formatAge(Date.now() - since);
    const state = stateWord(phase, waitingOnUser(ctx));
    // A frozen frame, not the animation: the title is rewritten by the OS.
    const lead = busy || phase === "working" ? `${WORK_GLYPH} ` : "";
    return `${lead}${text} · ${shortPath(cwd)} · ${age}${state ? ` · ${state}` : ""}`;
  };

  const paint = () => {
    const ctx = state.ctx;
    if (!ctx || !state.live) return;
    // Every tool call repaints; only rewrite the title when it changed, so the
    // titlebar does not flicker for a session that merely got older.
    const title = renderTitle(ctx);
    if (title !== paintedTitle) {
      paintedTitle = title;
      ctx.ui.setTitle(title);
    }
    state.tui?.requestRender();
  };

  /**
   * Pi owns the title too (`π - <name> - <cwd>`) and rewrites it on startup and
   * whenever the session name changes, which includes our own auto-naming. Win
   * that race once per rename instead of on every render.
   */
  const repaintSoon = () => {
    if (repaintTimer) clearTimeout(repaintTimer);
    repaintTimer = setTimeout(() => {
      repaintTimer = undefined;
      paintedTitle = "";
      paint();
    }, 250);
    repaintTimer.unref?.();
  };

  /**
   * One continuous line, inset like the footer's text: the leading and trailing
   * dashes stand in for its padding, and the detail is separated by the same
   * dashes instead of dots so the row reads as the top of the input box.
   * Detail is shed before the label is shortened.
   */
  const borderSides = (
    width: number,
    hidden: number,
    border: (text: string) => string,
    status: BorderStatus | undefined,
    levels: readonly Segment[][],
  ): { left: string; right: string; label?: { x0: number; x1: number }; controls: Region[] } => {
    const ctx = state.ctx;
    if (!ctx) return { left: "", right: "", controls: [] };
    const theme = ctx.ui.theme;
    const { text } = currentLabel(ctx);
    const stateText = stateWord(phase, waitingOnUser(ctx));
    // pi reports scrolled editor content as `↑ N more`; it describes the editor,
    // so it belongs next to the label rather than in the session detail.
    const hint = hidden > 0 ? ` ↑${hidden}` : "";
    const stateSegment: Segment[] = stateText
      ? [{ text: theme.fg(stateText === "failed" ? "error" : "warning", stateText) }]
      : [];
    // Measurements give way before the state, which is the part that asks you to look.
    const rows: Segment[][] = [...levels.map((level) => [...stateSegment, ...level]), stateSegment];
    if (stateSegment.length > 0) rows.push([]);
    // A retry, compaction or branch summary takes the label's slot: it carries
    // the countdown and the key that cancels it.
    const message = status && status.kind !== "working" ? status : undefined;
    // pi's own shape, `── ⠋ Working`, with the label where its message would be.
    const lead =
      status?.kind === "working"
        ? `${border("──")} ${status.renderSpinnerInBorder(width)} `
        : busy && !message
          ? `${border("──")} ${theme.fg("accent", WORK_GLYPH)} `
          : border("── ");
    const separator = border(" ── ");
    const tail = border(" ──");

    for (const row of rows) {
      const right =
        row.length > 0 ? ` ${row.map((segment) => segment.text).join(separator)}${tail}` : "";
      // lead + label + hint + space, then the detail, then at least one dash.
      const room = width - visibleWidth(lead) - visibleWidth(hint) - 2 - visibleWidth(right);
      if (room < MIN_LABEL_ROOM) continue;
      // Columns of the clickable measurements, counted from the start of `right`.
      const controls: Region[] = [];
      let column = 1;
      row.forEach((segment, index) => {
        if (index > 0) column += visibleWidth(separator);
        const segmentWidth = visibleWidth(segment.text);
        if (segment.id && segment.action) {
          controls.push({
            x0: column,
            x1: column + segmentWidth,
            id: segment.id,
            action: segment.action,
          });
        }
        column += segmentWidth;
      });
      if (message) {
        return {
          left: `${lead}${message.renderInBorder(room)}${theme.fg("dim", hint)} `,
          right,
          controls,
        };
      }
      // The label wears the input's own border color (pi keys it to the
      // thinking level), so it reads as box chrome rather than prompt text.
      const shown = truncateToWidth(text, room, "…");
      const label = state.hover === LABEL_ID ? theme.fg("text", shown) : border(shown);
      const x0 = visibleWidth(lead);
      return {
        left: `${lead}${label}${theme.fg("dim", hint)} `,
        right,
        label: { x0, x1: x0 + visibleWidth(shown) },
        controls,
      };
    }
    return { left: "", right: "", controls: [] };
  };

  const drawTop = (
    width: number,
    hidden: number,
    border: (text: string) => string,
    status: BorderStatus | undefined,
    levels: readonly Segment[][] = [],
  ): { line: string; regions: Region[] } => {
    const { left, right, label, controls } = borderSides(width, hidden, border, status, levels);
    const fill = Math.max(0, width - visibleWidth(left) - visibleWidth(right));
    const rightStart = visibleWidth(left) + fill;
    return {
      line: left + (fill > 0 ? border("─".repeat(fill)) : "") + right,
      // The label and the measurements that carry an action; the rest is plain border.
      regions: [
        ...(label
          ? [{ ...label, id: LABEL_ID, action: (ctx: ExtensionContext) => relabel(ctx, true) }]
          : []),
        ...controls.map((c) => ({ ...c, x0: rightStart + c.x0, x1: rightStart + c.x1 })),
      ],
    };
  };

  const model = (ctx: ExtensionContext) => {
    const configured = process.env.PI_IDENTITY_MODEL || NAME_MODEL;
    const found = catalogModel(ctx, configured);
    if (found) return found;
    if (!warnedModel) {
      warnedModel = true;
      ctx.ui.notify(
        `identity: ${configured} is not in the catalog, using the active model`,
        "warning",
      );
    }
    return ctx.model;
  };

  const buildPrompt = (ctx: ExtensionContext, current: string) => {
    const files = touchedFiles(ctx, cwd, TOUCHED_FILES);
    const lines = [`directory: ${shortPath(cwd)}`, `current label: ${current || "(none)"}`];
    if (files.length > 0) lines.push(`files touched: ${files.join(", ")}`);
    lines.push(
      "requests:",
      ...requests(ctx, RECENT_PROMPTS, PROMPT_CHARS).map((prompt) => `- ${prompt}`),
    );
    return lines.join("\n");
  };

  const relabel = async (ctx: ExtensionContext, manual: boolean) => {
    if (busy || !state.live) return;
    const name = explicitName();
    if (name) {
      if (manual) ctx.ui.notify(`identity: /name owns the label (${name})`, "warning");
      return;
    }
    if ((label?.calls ?? 0) >= CALL_CAP) {
      if (manual) ctx.ui.notify(`identity: label call cap (${CALL_CAP}) reached`, "warning");
      return;
    }
    const chosen = model(ctx);
    if (!chosen) {
      if (manual) ctx.ui.notify("identity: no model available for labeling", "warning");
      return;
    }

    const controller = new AbortController();
    inflight = controller;
    busy = true;
    paint();
    try {
      const current = currentLabel(ctx).text;
      const response = await ctx.modelRegistry
        .streamSimple(
          chosen,
          {
            systemPrompt: SYSTEM,
            messages: [
              {
                role: "user",
                content: [{ type: "text", text: buildPrompt(ctx, current) }],
                timestamp: Date.now(),
              },
            ],
          },
          {
            // deepseek spends 60-70 tokens thinking before it writes the label,
            // and a smaller cap comes back as `length` with no text at all.
            maxTokens: 256,
            temperature: 0,
            timeoutMs: 12_000,
            // The opencode gateway routes on `x-opencode-session`, which pi
            // derives from this; without it the request fails with 400.
            sessionId: ctx.sessionManager.getSessionId(),
            signal: controller.signal,
          },
        )
        .result();
      if (controller.signal.aborted) return;
      recordSideCall(pi, "session label", response);
      if (response.stopReason === "error" || response.stopReason === "aborted") {
        throw new Error(response.errorMessage ?? response.stopReason);
      }
      const reply = response.content
        .flatMap((block) => (block.type === "text" ? [block.text] : []))
        .join(" ");
      const text = cleanLabel(reply);
      if (text === "") throw new Error(`no text in reply (${response.stopReason})`);

      adopt({
        text,
        source: "model",
        at: Date.now(),
        calls: (label?.calls ?? 0) + 1,
        costUsd: (label?.costUsd ?? 0) + (response.usage?.cost?.total ?? 0),
      });
      persist();
    } catch (error) {
      if (manual && !controller.signal.aborted) {
        const reason = error instanceof Error ? error.message : String(error);
        ctx.ui.notify(`identity: relabel failed: ${reason}`, "error");
      }
    } finally {
      inflight = undefined;
      if (!controller.signal.aborted) {
        busy = false;
        paint();
      }
    }
  };

  const quote = (path: string) =>
    /^[a-zA-Z0-9_\-./~:@]+$/.test(path) ? path : `'${path.replace(/'/g, `'\\''`)}'`;

  const resumeCommand = () => `cd ${quote(cwd)} && pi --session ${shortId()}`;
  const summary = (ctx: ExtensionContext) => {
    const { text, source } = currentLabel(ctx);
    const calls = label?.calls ?? 0;
    const persisted = ctx.sessionManager.getSessionFile();
    return [
      `${text}  (${source})`,
      `path: ${cwd}`,
      persisted
        ? `session: ${sessionId()}`
        : "session: ephemeral (--no-session), nothing to resume",
      `labels: ${calls} call${calls === 1 ? "" : "s"} · ${formatCost(label?.costUsd ?? 0)}`,
      persisted ? `resume: ${resumeCommand()}` : undefined,
    ]
      .filter(Boolean)
      .join("\n");
  };

  const setManual = (text: string): "set" | "empty" | "named" => {
    const cleaned = cleanLabel(text);
    if (cleaned === "") return "empty";
    if (explicitName()) return "named";
    adopt({
      text: cleaned,
      source: "manual",
      at: Date.now(),
      calls: label?.calls ?? 0,
      costUsd: label?.costUsd ?? 0,
    });
    derivedCache = undefined;
    persist();
    paint();
    return "set";
  };

  pi.registerCommand("header", {
    description: "Session identity: relabel, copy resume command, show path and id",
    handler: async (args, ctx) => {
      const trimmed = args.trim();
      if (trimmed) {
        const result = setManual(trimmed);
        if (result === "empty") ctx.ui.notify("identity: empty label ignored", "warning");
        if (result === "named")
          ctx.ui.notify("identity: /name owns the label, run /name to change it", "warning");
        return;
      }
      ctx.ui.notify(summary(ctx), "info");
      if (!ctx.hasUI) return;
      const choice = await ctx.ui.select("Session identity", [
        "Relabel now",
        "Copy resume command",
        "Set label…",
      ]);
      if (choice === "Relabel now") await relabel(ctx, true);
      else if (choice === "Copy resume command") {
        if (!ctx.sessionManager.getSessionFile()) {
          ctx.ui.notify("identity: this session is ephemeral (--no-session)", "warning");
          return;
        }
        await copyToClipboard(resumeCommand());
        ctx.ui.notify("identity: resume command copied", "info");
      } else if (choice === "Set label…") {
        const input = await ctx.ui.input("Session label", currentLabel(ctx).text);
        if (!input) return;
        const result = setManual(input);
        if (result === "named")
          ctx.ui.notify("identity: /name owns the label, run /name to change it", "warning");
      }
    },
  });

  pi.registerShortcut(SHORTCUT, {
    description: "Relabel this session",
    handler: (ctx) => relabel(ctx, true),
  });

  // Before this module's own ui_prompt_start handler, which reads the state it keeps.
  trackUserWait(pi);

  pi.on("session_start", (_event, ctx) => {
    cwd = ctx.cwd;
    // The last persisted label on this branch wins, so a resumed session paints
    // instantly and without a model call.
    let firstModel: string | undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === CUSTOM_TYPE) {
        const data = entry.data as (Partial<Label> & { namedSession?: boolean }) | undefined;
        if (data && typeof data.text === "string" && data.text !== "") {
          const source = data.source ?? "model";
          if (source === "model") firstModel ??= data.text;
          label = {
            text: data.text,
            source,
            at: data.at ?? Date.now(),
            calls: data.calls ?? 0,
            costUsd: data.costUsd ?? 0,
            // Labels from before autoName mark that the first model label named the session.
            autoName: data.autoName ?? (data.namedSession ? firstModel : undefined),
          };
        }
      }
    }
    setAutoName(sessionId(), label?.autoName);

    if (!state.live) return;
    timer = setInterval(paint, TICK_MS);
    timer.unref?.();
    paint();
    repaintSoon();
  });

  pi.on("agent_start", () => {
    since = Date.now();
    phase = "working";
    paint();
  });

  pi.on("agent_settled", () => {
    since = Date.now();
    // Failure is sticky until the next run starts.
    if (phase !== "failed") phase = "idle";
    paint();
  });

  // Only a dialog the run is blocked on says "waiting"; the phase underneath is
  // untouched, so the spinner stays and a run that settles meanwhile shows it.
  const promptChanged = (ctx: ExtensionContext) => {
    const waiting = waitingOnUser(ctx);
    if (waiting !== waited) {
      waited = waiting;
      since = Date.now();
    }
    paint();
  };
  pi.on("ui_prompt_start", (_event, ctx) => promptChanged(ctx));
  pi.on("ui_prompt_end", (_event, ctx) => promptChanged(ctx));

  pi.on("message_end", (event) => {
    if (event.message.role === "assistant" && event.message.stopReason === "error") {
      phase = "failed";
    }
    paint();
  });

  pi.on("tool_execution_end", () => paint());

  pi.on("session_compact", (_event, ctx) => {
    // Compaction already paid for a summary, so the marginal label is cheap and
    // the work has usually moved on by the time one happens.
    void relabel(ctx, false).catch(() => {});
    paint();
  });

  pi.on("session_info_changed", () => {
    paint();
    repaintSoon();
  });

  pi.on("session_shutdown", () => {
    inflight?.abort();
    setAutoName(sessionId(), undefined);
    if (timer) clearInterval(timer);
    timer = undefined;
    if (repaintTimer) clearTimeout(repaintTimer);
    repaintTimer = undefined;
    state.tui = undefined;
    if (state.ctx && state.live) {
      // Leave an honest title for the shell prompt that follows; the fish title
      // takes over from here, but a crash-free exit should not show a stale run.
      const { text } = currentLabel(state.ctx);
      state.ctx.ui.setTitle(`${text} · ${shortPath(cwd)}`);
    }
  });

  return { drawTop, relabel };
};
