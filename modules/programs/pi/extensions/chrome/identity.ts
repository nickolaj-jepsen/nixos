/**
 * Which pi am I looking at: the terminal title, the editor's top border, and
 * `/header`.
 *
 * The title is the only surface visible from the niri overview, so it stays
 * terse: task label, directory, age, and a state word only when the session
 * wants you. The border row is the persistent one inside pi: the label, the
 * step in flight while the agent works, pi's scroll hint, the state word and
 * the measurements. pi's working spinner sits in front of the label, and a
 * retry, compaction or branch summary takes its place. `/header` shows the
 * details and the resume command.
 *
 * The label is model-written, not cut from the first prompt: a sidecar call
 * (`lib/sidecar.ts`) runs at each substantive turn, beside the run, and is
 * asked to repeat the current label when the work has not moved on. So the name
 * follows the work instead of freezing on one sentence, and the directory is
 * never a name, since the footer already carries it. Until the first call lands
 * the border is plain; the deterministic cut of the first prompt survives only
 * as the fallback for a session the model could not name.
 *
 * The border belongs to the editor; the wrapper in `editor.ts` calls `drawTop`
 * for the border row. Until you run `/name`, the session name follows the label,
 * so `/resume` lists something useful.
 */
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
  isAcknowledgement,
  NAME_MODEL,
  oneLine,
  stripRequest,
} from "../lib/naming.ts";
import { ask, buildPrompt, type Fields, MAX_DOING, parseFields } from "../lib/sidecar.ts";
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
type Source = "name" | "model" | "manual" | "prompt";

type Label = {
  text: string;
  source: Source;
  at: number;
  /** The session name this extension last wrote; any other name is the user's `/name`. */
  autoName?: string;
};

/** What the sidecar says beside the label; it outlives a rename and survives `/name`. */
type Meta = { summary?: string; tags?: readonly string[] };

/** The persisted record. Entries from before the sidecar lack its optional fields. */
type Persisted = {
  text?: string;
  source?: Source;
  at?: number;
  calls?: number;
  costUsd?: number;
  summary?: string;
  tags?: string[];
  autoName?: string;
  /** Labels from before autoName mark that the first model label named the session. */
  namedSession?: boolean;
};

const CUSTOM_TYPE = "identity_label";
const SHORTCUT = "alt+r";
const TICK_MS = 60_000;
// A runaway guard rather than a budget: a call costs ~$0.0002 and a turn buys one.
const CALL_CAP = 200;
// A paste and the follow-up that corrects it are one turn's naming, not two.
const MIN_CALL_GAP_MS = 10_000;
// A dead gateway should stop being asked, not be asked again every turn.
const MAX_FAILURES = 3;
const MAX_LABEL_CHARS = 40;
// Below this the label stops being the point of the row, so shed the detail first.
const MIN_LABEL_ROOM = 14;
// A step cut shorter than this says nothing worth the columns.
const MIN_DOING_ROOM = 8;

// Sub-agent widgets already own `●`, `○`, `⟳` and `▸`, so states that need you
// are words and "working" is either pi's spinner or a frozen frame of one.
const WORK_GLYPH = "⠿";
const stateWord = (phase: Phase, waiting: boolean) =>
  waiting ? "waiting" : phase === "failed" ? "failed" : "";

const cleanLabel = (raw: string) => {
  const first = oneLine(raw).replace(/^(label|session|task)\s*:\s*/i, "");
  const unquoted = first
    .replace(/^["'`]+|["'`.,;:]+$/g, "")
    // A name is letters, digits, spaces and the odd hyphen: an emoji or a stray
    // bracket from a small model costs two columns and reads as decoration.
    .replace(/[^\p{L}\p{N} '\-/]/gu, "")
    .replace(/\s+/g, " ")
    .trim();
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
  let meta: Meta = {};
  let calls = 0;
  let costUsd = 0;
  let failures = 0;
  let lastCallAt = 0;
  /** A label the user set here, which `/name` aside is the only one the model must not touch. */
  let manualName = false;
  /** The step the last call named; shown while the turn runs, dropped when it settles. */
  let doing: string | undefined;

  const sessionId = () => state.ctx?.sessionManager.getSessionId() ?? "";
  const shortId = () => sessionId().slice(0, 8);

  const persist = () => {
    const data: Persisted = {
      text: label?.text,
      source: label?.source,
      at: label?.at ?? Date.now(),
      calls,
      costUsd,
      summary: meta.summary,
      tags: meta.tags ? [...meta.tags] : undefined,
      autoName: label?.autoName,
    };
    pi.appendEntry<Persisted>(CUSTOM_TYPE, data);
  };

  /**
   * A session name we did not write is the user's choice through `/name`, and
   * it outranks anything this extension would generate.
   */
  const explicitName = () => {
    const name = pi.getSessionName();
    return name && name !== label?.autoName ? name : undefined;
  };

  /** Whether the label is the user's to set, through `/name` or a label set here. */
  const ownsLabel = () => manualName || explicitName() !== undefined;

  /**
   * Stores a model or manual label and, unless the user owns the name, renames
   * the session to match: `/resume` lists sessions by name, the one place the
   * label helps before the window is even open.
   */
  const adopt = (next: Omit<Label, "autoName">) => {
    const owned = ownsLabel();
    label = { ...next, autoName: owned ? label?.autoName : next.text };
    if (owned) return;
    setAutoName(sessionId(), next.text);
    if (pi.getSessionName() !== next.text) pi.setSessionName(next.text);
  };

  /** The first request cut to a name: only for a session the model could not reach. */
  const fallback = (ctx: ExtensionContext) =>
    failures > 0 ? cleanLabel(stripRequest(firstRequest(ctx) ?? "")) : "";

  const currentLabel = (ctx: ExtensionContext): Label | undefined => {
    const name = explicitName();
    if (name) return { text: name, source: "name", at: label?.at ?? Date.now() };
    if (label) return label;
    const text = fallback(ctx);
    return text ? { text, source: "prompt", at: Date.now() } : undefined;
  };

  const renderTitle = (ctx: ExtensionContext) => {
    const text = currentLabel(ctx)?.text;
    const age = formatAge(Date.now() - since);
    const stateText = stateWord(phase, waitingOnUser(ctx));
    // A frozen frame, not the animation: the title is rewritten by the OS.
    const lead = phase === "working" ? `${WORK_GLYPH} ` : "";
    return `${lead}${text ? `${text} · ` : ""}${shortPath(cwd)} · ${age}${
      stateText ? ` · ${stateText}` : ""
    }`;
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
    const current = currentLabel(ctx);
    const name = current?.text ?? "";
    // A step is a plan made at turn start, so it is shown only while that turn runs.
    const step = phase === "working" ? doing : undefined;
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
          const pad = segment.hitPad ?? 0;
          controls.push({
            x0: column - pad,
            x1: column + segmentWidth + pad,
            id: segment.id,
            action: segment.action,
          });
        }
        column += segmentWidth;
      });
      // A padded target must not swallow its neighbour: two of them split the gap
      // between them, so a click near the border, or the pointer's hover, still
      // picks the control it is closest to.
      for (let i = 1; i < controls.length; i++) {
        const left = controls[i - 1];
        const right = controls[i];
        if (left && right && left.x1 > right.x0) {
          const middle = Math.floor((left.x1 + right.x0) / 2);
          left.x1 = middle;
          right.x0 = middle;
        }
      }
      if (message) {
        return {
          left: `${lead}${message.renderInBorder(room)}${theme.fg("dim", hint)} `,
          right,
          controls,
        };
      }
      // The label wears the input's own border color (pi keys it to the
      // thinking level), so it reads as box chrome rather than prompt text.
      const shown = name ? truncateToWidth(name, room, "…") : "";
      // The step gives way before the label is shortened: it is the part that can lie.
      const roomForStep = room - visibleWidth(shown) - 3;
      const shownStep =
        step && shown === name && roomForStep >= MIN_DOING_ROOM
          ? truncateToWidth(step, roomForStep, "…")
          : undefined;
      const painted =
        current?.source === "prompt"
          ? theme.fg("dim", shown)
          : state.hover === LABEL_ID
            ? theme.fg("text", shown)
            : border(shown);
      const detail = shownStep ? `${theme.fg("dim", " · ")}${theme.fg("dim", shownStep)}` : "";
      const x0 = visibleWidth(lead);
      return {
        left: `${lead}${painted}${detail}${theme.fg("dim", hint)}${name ? " " : ""}`,
        right,
        label: name ? { x0, x1: x0 + visibleWidth(shown) } : undefined,
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
          ? [{ ...label, id: LABEL_ID, action: (ctx: ExtensionContext) => refresh(ctx, true) }]
          : []),
        ...controls.map((c) => ({ ...c, x0: rightStart + c.x0, x1: rightStart + c.x1 })),
      ],
    };
  };

  /**
   * The model to ask. A missing one is a warning, not a reason to spend the
   * session's own model: an automatic fallback would name the session on every
   * turn at roughly thirty times the price of the one it was told to use.
   */
  const model = (ctx: ExtensionContext, manual: boolean) => {
    const configured = process.env.PI_IDENTITY_MODEL || NAME_MODEL;
    const found = catalogModel(ctx, configured);
    if (found) return found;
    if (!warnedModel) {
      warnedModel = true;
      ctx.ui.notify(
        `identity: ${configured} is not in the catalog${
          manual ? ", using the active model" : ", not labeling with the active model"
        }`,
        "warning",
      );
    }
    return manual ? ctx.model : undefined;
  };

  /** Takes what the sidecar said, keeping whatever it left out. */
  const apply = (fields: Fields) => {
    if (fields.summary) meta = { ...meta, summary: fields.summary };
    if (fields.tags) meta = { ...meta, tags: fields.tags };
    // An omitted key keeps the step; an empty one clears it.
    if (phase === "working" && fields.doing !== undefined) {
      doing = fields.doing ? oneLine(fields.doing).slice(0, MAX_DOING) : undefined;
    }
    const next = fields.label ? cleanLabel(fields.label) : "";
    if (next && next !== label?.text && !ownsLabel()) {
      adopt({ text: next, source: "model", at: Date.now() });
      repaintSoon();
    }
    persist();
  };

  /**
   * Asks the sidecar for the session's identity. `manual` is a click or the
   * shortcut, which skips the debounce and reports failures instead of hiding them.
   */
  const refresh = async (ctx: ExtensionContext, manual = false) => {
    if (!state.live || busy) return;
    const muted = failures >= MAX_FAILURES;
    const capped = calls >= CALL_CAP;
    if (muted || capped) {
      if (manual) {
        ctx.ui.notify(
          muted
            ? "identity: the label model keeps failing, staying quiet until the next session"
            : `identity: label call cap (${CALL_CAP}) reached`,
          "warning",
        );
      }
      return;
    }
    if (!manual && Date.now() - lastCallAt < MIN_CALL_GAP_MS) return;
    const chosen = model(ctx, manual);
    if (!chosen) return;

    const controller = new AbortController();
    inflight = controller;
    busy = true;
    lastCallAt = Date.now();
    try {
      const current = currentLabel(ctx);
      // A fallback is a cut of the user's sentence, not a name: do not ask the
      // model to repeat it, or the first guess becomes sticky.
      const prompt = buildPrompt(ctx, {
        label: current?.source === "prompt" ? undefined : current?.text,
        summary: meta.summary,
        tags: meta.tags,
      });
      const response = await ask(ctx, chosen, prompt, controller.signal);
      if (controller.signal.aborted) return;
      recordSideCall(pi, "session label", response);
      if (response.stopReason === "error" || response.stopReason === "aborted") {
        throw new Error(response.errorMessage ?? response.stopReason);
      }
      const reply = response.content
        .flatMap((block) => (block.type === "text" ? [block.text] : []))
        .join("\n");
      const fields = parseFields(reply);
      if (Object.keys(fields).length === 0) {
        throw new Error(`no fields in reply (${response.stopReason})`);
      }
      calls += 1;
      costUsd += response.usage?.cost?.total ?? 0;
      failures = 0;
      apply(fields);
    } catch (error) {
      failures += 1;
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
    const current = currentLabel(ctx);
    const persisted = ctx.sessionManager.getSessionFile();
    return [
      `${current?.text ?? "(unnamed)"}  (${current?.source ?? "none"})`,
      meta.summary,
      meta.tags?.length ? `tags: ${meta.tags.join(", ")}` : undefined,
      phase === "working" && doing ? `doing: ${doing}` : undefined,
      `path: ${cwd}`,
      persisted
        ? `session: ${sessionId()}`
        : "session: ephemeral (--no-session), nothing to resume",
      `label calls: ${calls} · ${formatCost(costUsd)}`,
      persisted ? `resume: ${resumeCommand()}` : undefined,
    ]
      .filter(Boolean)
      .join("\n");
  };

  const setManual = (text: string): "set" | "empty" | "owned" => {
    const cleaned = cleanLabel(text);
    if (cleaned === "") return "empty";
    if (explicitName()) return "owned";
    manualName = true;
    adopt({ text: cleaned, source: "manual", at: Date.now() });
    persist();
    paint();
    return "set";
  };

  const reportManual = (ctx: ExtensionContext, result: "set" | "empty" | "owned") => {
    if (result === "empty") ctx.ui.notify("identity: empty label ignored", "warning");
    if (result === "owned")
      ctx.ui.notify("identity: /name owns the label, run /name to change it", "warning");
  };

  pi.registerCommand("header", {
    description: "Session identity: relabel, copy resume command, show path and id",
    handler: async (args, ctx) => {
      const trimmed = args.trim();
      if (trimmed) {
        reportManual(ctx, setManual(trimmed));
        return;
      }
      ctx.ui.notify(summary(ctx), "info");
      if (!ctx.hasUI) return;
      const choice = await ctx.ui.select("Session identity", [
        "Refresh label now",
        "Copy resume command",
        "Set label…",
      ]);
      if (choice === "Refresh label now") await refresh(ctx, true);
      else if (choice === "Copy resume command") {
        if (!ctx.sessionManager.getSessionFile()) {
          ctx.ui.notify("identity: this session is ephemeral (--no-session)", "warning");
          return;
        }
        await copyToClipboard(resumeCommand());
        ctx.ui.notify("identity: resume command copied", "info");
      } else if (choice === "Set label…") {
        const input = await ctx.ui.input("Session label", currentLabel(ctx)?.text ?? "");
        if (!input) return;
        reportManual(ctx, setManual(input));
      }
    },
  });

  pi.registerShortcut(SHORTCUT, {
    description: "Relabel this session now",
    handler: (ctx) => refresh(ctx, true),
  });

  // Before this module's own ui_prompt_start handler, which reads the state it keeps.
  trackUserWait(pi);

  pi.on("session_start", (_event, ctx) => {
    cwd = ctx.cwd;
    // The last persisted record on this branch wins, so a resumed session paints
    // instantly and without a model call.
    let firstModel: string | undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "custom" || entry.customType !== CUSTOM_TYPE) continue;
      const data = entry.data as Persisted | undefined;
      if (!data) continue;
      if (typeof data.calls === "number") calls = data.calls;
      if (typeof data.costUsd === "number") costUsd = data.costUsd;
      if (typeof data.summary === "string") meta = { ...meta, summary: data.summary };
      if (Array.isArray(data.tags)) {
        meta = { ...meta, tags: data.tags.filter((tag) => typeof tag === "string") };
      }
      if (typeof data.text !== "string" || data.text === "") continue;
      // The directory was never a name, so an old entry that recorded it as one
      // leaves the session unnamed for the next call to fix.
      const stored = data.source as Source | "cwd" | undefined;
      if (stored === "cwd") continue;
      const source = stored ?? "model";
      if (source === "model") firstModel ??= data.text;
      manualName = source === "manual";
      label = {
        text: data.text,
        source,
        at: data.at ?? Date.now(),
        // Labels from before autoName mark that the first model label named the session.
        autoName: data.autoName ?? (data.namedSession ? firstModel : undefined),
      };
    }
    setAutoName(sessionId(), label?.autoName);

    if (!state.live) return;
    timer = setInterval(paint, TICK_MS);
    timer.unref?.();
    paint();
    repaintSoon();
  });

  // The turn's request is new information, and the call runs beside the run
  // rather than after it, so the name is ready by the time anyone looks up.
  pi.on("before_agent_start", (event, ctx) => {
    if (event.messageType !== "user") return;
    if (isAcknowledgement(event.prompt)) return;
    void refresh(ctx).catch(() => {});
  });

  pi.on("agent_start", () => {
    since = Date.now();
    phase = "working";
    // The turn's step is unknown until its call answers.
    doing = undefined;
    paint();
  });

  pi.on("agent_settled", () => {
    since = Date.now();
    // Failure is sticky until the next run starts.
    if (phase !== "failed") phase = "idle";
    // The step described a turn that is over.
    doing = undefined;
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
    // Compaction already paid for a summary, so the marginal call is cheap and
    // the work has usually moved on by the time one happens.
    void refresh(ctx).catch(() => {});
    paint();
  });

  pi.on("session_info_changed", () => {
    paint();
    repaintSoon();
  });

  pi.on("session_shutdown", () => {
    inflight?.abort();
    inflight = undefined;
    busy = false;
    setAutoName(sessionId(), undefined);
    if (timer) clearInterval(timer);
    timer = undefined;
    if (repaintTimer) clearTimeout(repaintTimer);
    repaintTimer = undefined;
    state.tui = undefined;
    if (state.ctx && state.live) {
      // Leave an honest title for the shell prompt that follows; the fish title
      // takes over from here, but a crash-free exit should not show a stale run.
      const text = currentLabel(state.ctx)?.text;
      state.ctx.ui.setTitle(`${text ? `${text} · ` : ""}${shortPath(cwd)}`);
    }
  });

  return { drawTop, refresh };
};
