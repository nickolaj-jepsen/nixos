/**
 * The session's label and what the last turn wants from you, kept by the
 * sidecar (`shared/sidecar.ts`) and persisted on the branch; `border.ts` and
 * `title.ts` paint them.
 *
 * The label is model-written, not cut from the first prompt: a sidecar call
 * runs at each substantive turn, beside the run, and is asked to repeat the
 * current label when the work has not moved on. So the name follows the work
 * instead of freezing on one sentence, and the directory is never a name, since
 * the footer already carries it. The deterministic cut of the first prompt
 * survives only as the fallback for a session the model could not name.
 *
 * A second call reads the turn once it settles, for the one thing a wall of
 * prose hides: what it wants from you. That ask becomes the border's detail
 * when the agent is idle, and its draft answer a suggestion on the input line.
 * The same call says whether the turn finished, waits on you or gave up. The
 * call is skipped for a turn that ran no tools and said little, since those are
 * read at a glance.
 *
 * Every reading is broadcast on `SIDECAR_CHANNEL`, so other extensions can use
 * it without paying for a call of their own. Until you run `/name`, the session
 * name follows the label, so `/resume` lists something useful.
 */
import {
  copyToClipboard,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { setAutoName } from "../lib/auto-name.ts";
import { firstRequest, isAcknowledgement, oneLine, stripRequest } from "../../shared/naming.ts";
import {
  ask as askSidecar,
  buildPrompt,
  type Fields,
  IDENTITY_ENTRY,
  MAX_DOING,
  parseFields,
  SIDECAR_CHANNEL,
  type SidecarUpdate,
  type TurnState,
} from "../../shared/sidecar.ts";
import { waitingOnUser } from "../lib/user-wait.ts";
import type { ChromeState } from "./state.ts";

type Phase = "working" | "idle" | "failed";
type Source = "name" | "model" | "prompt";
/** Which moment the call is reading: a request that just arrived, or a turn that just ended. */
type Moment = "start" | "settle";

export type Label = {
  text: string;
  source: Source;
  /** The session name this extension last wrote; any other name is the user's `/name`. */
  autoName?: string;
};

/** What the sidecar says beside the label; it outlives a rename and survives `/name`. */
type Meta = { summary?: string; tags?: readonly string[] };

/** The persisted record, as read back: any field may be missing. */
type Persisted = {
  text?: string;
  calls?: number;
  summary?: string;
  tags?: string[];
  autoName?: string;
};

const SHORTCUT = "alt+r";
// A runaway guard rather than a budget: a call costs ~$0.0002 and a turn buys one.
const CALL_CAP = 200;
// A paste and the follow-up that corrects it are one turn's naming, not two.
const MIN_CALL_GAP_MS = 10_000;
// A dead gateway should stop being asked, not be asked again every turn.
const MAX_FAILURES = 3;
const MAX_LABEL_CHARS = 40;
// A turn that ran no tools and wrote less than this is read at a glance, so the
// settle call would only tell you what is already on screen.
const WORTH_ASKING_CHARS = 800;
// Drafts passed over this many turns running are noise; from then on only every
// few turns gets one, until one is taken.
const REPLY_BACKOFF_AFTER = 4;
const REPLY_BACKOFF_EVERY = 3;

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

export const createLabel = (pi: ExtensionAPI, state: ChromeState) => {
  let cwd = process.cwd();
  let phase: Phase = "idle";
  let busy = false;
  // Aborted at session_shutdown, after which every ctx and pi call throws.
  let inflight: AbortController | undefined;
  let label: Label | undefined;
  let meta: Meta = {};
  let calls = 0;
  let failures = 0;
  let lastCallAt = 0;
  let changed = () => {};
  /** A settle call that arrived while the turn-start call was still out. */
  let pending: Moment | undefined;
  /** The step the last call named; shown while the turn runs, dropped when it settles. */
  let doing: string | undefined;
  /** What the finished turn asked for, and the draft that answers it. Both die with the next turn. */
  let ask: string | undefined;
  let reply: string | undefined;
  /** How the finished turn ended, by the settle call's reading; dies with the next turn. */
  let turnState: TurnState | undefined;
  /** Whether a draft was on offer for the last turn, and how many turns running one went untaken. */
  let offered = false;
  let unusedReplies = 0;
  let backedOff = 0;
  /** What the running turn has done so far, for deciding whether its outcome is worth a call. */
  let turnTools = 0;
  let lastText = 0;

  const sessionId = () => state.ctx?.sessionManager.getSessionId() ?? "";

  const paint = () => {
    changed();
    state.tui?.requestRender();
  };

  const persist = () => {
    const data: Persisted = {
      text: label?.text,
      calls,
      summary: meta.summary,
      tags: meta.tags ? [...meta.tags] : undefined,
      autoName: label?.autoName,
    };
    pi.appendEntry<Persisted>(IDENTITY_ENTRY, data);
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
   * Stores a model label and, unless the user named the session, renames it to
   * match: `/resume` lists sessions by name, the one place the label helps
   * before the window is even open.
   */
  const adopt = (text: string) => {
    label = { text, source: "model", autoName: text };
    setAutoName(sessionId(), text);
    if (pi.getSessionName() !== text) pi.setSessionName(text);
  };

  /** The first request cut to a name: only for a session the model could not reach. */
  const fallback = (ctx: ExtensionContext) =>
    failures > 0 ? cleanLabel(stripRequest(firstRequest(ctx) ?? "")) : "";

  const current = (ctx: ExtensionContext): Label | undefined => {
    const name = explicitName();
    if (name) return { text: name, source: "name" };
    if (label) return label;
    const text = fallback(ctx);
    return text ? { text, source: "prompt" } : undefined;
  };

  // Sub-agent widgets already own `●`, `○`, `⟳` and `▸`, so states that need you
  // are words and "working" is either pi's spinner or a frozen frame of one.
  const stateWord = (ctx: ExtensionContext) =>
    waitingOnUser(ctx)
      ? "waiting"
      : phase === "failed" || (phase === "idle" && turnState === "failed")
        ? "failed"
        : phase === "idle" && turnState === "blocked"
          ? "needs you"
          : "";

  /** Tells other extensions what the sidecar knows now; `asked` is false when no call was made. */
  const announce = (moment: Moment, asked: boolean) => {
    const update: SidecarUpdate = {
      sessionId: sessionId(),
      moment,
      asked,
      label: state.ctx ? current(state.ctx)?.text : label?.text,
      summary: meta.summary,
      doing: phase === "working" ? doing : undefined,
      state: moment === "settle" ? turnState : undefined,
      ask: moment === "settle" ? ask : undefined,
    };
    pi.events.emit(SIDECAR_CHANNEL, update);
  };

  /**
   * The draft to offer, if any. After enough untaken drafts in a row, only every
   * few turns gets one: a row you keep reading past is clutter.
   */
  const offer = (draft: string | undefined) => {
    if (!draft) return undefined;
    if (unusedReplies >= REPLY_BACKOFF_AFTER && ++backedOff % REPLY_BACKOFF_EVERY !== 0) {
      return undefined;
    }
    offered = true;
    return draft;
  };

  /** Takes what the sidecar said, keeping whatever it left out. */
  const apply = (fields: Fields, moment: Moment) => {
    if (fields.summary) meta = { ...meta, summary: fields.summary };
    if (fields.tags) meta = { ...meta, tags: fields.tags };
    // An omitted key keeps the step; an empty one clears it.
    if (phase === "working" && fields.doing !== undefined) {
      doing = fields.doing ? oneLine(fields.doing).slice(0, MAX_DOING) : undefined;
    }
    // Only a turn that ended has anything to ask for; at turn start the keys are
    // guesses about work that has not happened.
    if (moment === "settle") {
      ask = fields.ask ? oneLine(fields.ask) : undefined;
      reply = ask ? offer(oneLine(fields.reply ?? "") || undefined) : undefined;
      // An open question is the person's turn whatever the model called it.
      turnState = ask ? "blocked" : fields.state;
    }
    const next = fields.label ? cleanLabel(fields.label) : "";
    if (next && next !== label?.text && explicitName() === undefined) adopt(next);
    persist();
    announce(moment, true);
  };

  /**
   * Asks the sidecar for the session's identity. `manual` is a click or the
   * shortcut, which skips the debounce and reports failures instead of hiding them.
   */
  const refresh = async (ctx: ExtensionContext, manual = false, moment: Moment = "start") => {
    // A settled turn is announced whether or not it gets a call, so nobody waits on one.
    const skip = () => {
      if (moment === "settle") announce(moment, false);
    };
    if (!state.live) return skip();
    if (busy) {
      // A turn that settles while the turn-start call is still out keeps its ask:
      // it runs as soon as that call is done.
      if (moment === "settle") pending = "settle";
      return;
    }
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
      return skip();
    }
    // A settled turn is one call no matter how quickly it followed the last one;
    // the debounce exists for prompts typed in bursts.
    if (!manual && moment === "start" && Date.now() - lastCallAt < MIN_CALL_GAP_MS) return;

    const controller = new AbortController();
    inflight = controller;
    busy = true;
    lastCallAt = Date.now();
    try {
      const shown = current(ctx);
      // A fallback is a cut of the user's sentence, not a name: do not ask the
      // model to repeat it, or the first guess becomes sticky.
      const prompt = await buildPrompt(ctx, {
        label: shown?.source === "prompt" ? undefined : shown?.text,
        summary: meta.summary,
        tags: meta.tags,
        settle: moment === "settle",
      });
      if (controller.signal.aborted) return;
      const reply = await askSidecar(pi, ctx, prompt, moment, controller.signal);
      if (controller.signal.aborted) return;
      // Counted on any outcome, so a model that keeps failing still meets CALL_CAP.
      calls += 1;
      if ("error" in reply) throw new Error(reply.error);
      const fields = parseFields(reply.text);
      if (Object.keys(fields).length === 0) throw new Error("no fields in reply");
      failures = 0;
      apply(fields, moment);
    } catch (error) {
      failures += 1;
      if (!controller.signal.aborted) skip();
      if (manual && !controller.signal.aborted) {
        const reason = error instanceof Error ? error.message : String(error);
        ctx.ui.notify(`identity: relabel failed: ${reason}`, "error");
      }
    } finally {
      inflight = undefined;
      if (!controller.signal.aborted) {
        busy = false;
        paint();
        const next = pending;
        pending = undefined;
        const live = state.ctx;
        if (next && live) void refresh(live, false, next).catch(() => {});
      }
    }
  };

  const quote = (path: string) =>
    /^[a-zA-Z0-9_\-./~:@]+$/.test(path) ? path : `'${path.replace(/'/g, `'\\''`)}'`;

  const resumeCommand = () => `cd ${quote(cwd)} && pi --session ${sessionId().slice(0, 8)}`;
  const summary = (ctx: ExtensionContext) => {
    const shown = current(ctx);
    const persisted = ctx.sessionManager.getSessionFile();
    return [
      `${shown?.text ?? "(unnamed)"}  (${shown?.source ?? "none"})`,
      meta.summary,
      meta.tags?.length ? `tags: ${meta.tags.join(", ")}` : undefined,
      phase === "working" && doing ? `doing: ${doing}` : undefined,
      ask ? `needs: ${ask}` : undefined,
      reply ? `reply: ${reply}` : undefined,
      turnState ? `last turn: ${turnState}` : undefined,
      `path: ${cwd}`,
      persisted
        ? `session: ${sessionId()}`
        : "session: ephemeral (--no-session), nothing to resume",
      `label calls: ${calls}`,
      persisted ? `resume: ${resumeCommand()}` : undefined,
    ]
      .filter(Boolean)
      .join("\n");
  };

  pi.registerCommand("header", {
    description: "Session identity: relabel, copy resume command, show path and id",
    handler: async (_args, ctx) => {
      ctx.ui.notify(summary(ctx), "info");
      if (!ctx.hasUI) return;
      const choice = await ctx.ui.select("Session identity", [
        "Refresh label now",
        "Copy resume command",
      ]);
      if (choice === "Refresh label now") await refresh(ctx, true);
      else if (choice === "Copy resume command") {
        if (!ctx.sessionManager.getSessionFile()) {
          ctx.ui.notify("identity: this session is ephemeral (--no-session)", "warning");
          return;
        }
        await copyToClipboard(resumeCommand());
        ctx.ui.notify("identity: resume command copied", "info");
      }
    },
  });

  pi.registerShortcut(SHORTCUT, {
    description: "Relabel this session now",
    handler: (ctx) => refresh(ctx, true),
  });

  pi.on("session_start", (_event, ctx) => {
    cwd = ctx.cwd;
    // The last persisted record on this branch wins, so a resumed session paints
    // instantly and without a model call.
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "custom" || entry.customType !== IDENTITY_ENTRY) continue;
      const data = entry.data as Persisted | undefined;
      if (!data) continue;
      if (typeof data.calls === "number") calls = data.calls;
      if (typeof data.summary === "string") meta = { ...meta, summary: data.summary };
      if (Array.isArray(data.tags)) {
        meta = { ...meta, tags: data.tags.filter((tag) => typeof tag === "string") };
      }
      if (typeof data.text === "string" && data.text !== "") {
        label = { text: data.text, source: "model", autoName: data.autoName };
      }
    }
    setAutoName(sessionId(), label?.autoName);
  });

  // The turn's request is new information, and the call runs beside the run
  // rather than after it, so the name is ready by the time anyone looks up.
  pi.on("before_agent_start", (event, ctx) => {
    // Only your own prompt passes a draft over; a peer's message or a steer does not.
    if (offered && event.messageType === "user") {
      unusedReplies += 1;
      if (unusedReplies === REPLY_BACKOFF_AFTER && ctx.hasUI) {
        ctx.ui.notify(
          "identity: fewer reply drafts from now on; take one with tab to bring them back",
          "info",
        );
      }
    }
    offered = false;
    // A new turn retires the last one's ask, its draft, its state and its step.
    ask = undefined;
    reply = undefined;
    turnState = undefined;
    doing = undefined;
    if (event.messageType !== "user") return;
    if (isAcknowledgement(event.prompt)) return;
    void refresh(ctx).catch(() => {});
  });

  pi.on("agent_start", () => {
    phase = "working";
    turnTools = 0;
    lastText = 0;
  });

  pi.on("tool_execution_start", () => {
    turnTools += 1;
  });

  pi.on("agent_settled", (_event, ctx) => {
    // Failure is sticky until the next run starts.
    if (phase !== "failed") phase = "idle";
    // The step described a turn that is over.
    doing = undefined;
    if (turnTools > 0 || lastText >= WORTH_ASKING_CHARS) {
      void refresh(ctx, false, "settle").catch(() => {});
    } else {
      announce("settle", false);
    }
  });

  pi.on("message_end", (event) => {
    if (event.message.role !== "assistant") return;
    if (event.message.stopReason === "error") phase = "failed";
    const text = event.message.content
      .flatMap((block) => (block.type === "text" ? [block.text] : []))
      .join(" ");
    if (text.trim() !== "") lastText = text.length;
  });

  pi.on("session_compact", (_event, ctx) => {
    // Compaction already paid for a summary, so the marginal call is cheap and
    // the work has usually moved on by the time one happens.
    void refresh(ctx).catch(() => {});
  });

  pi.on("session_shutdown", () => {
    inflight?.abort();
    inflight = undefined;
    pending = undefined;
    busy = false;
    setAutoName(sessionId(), undefined);
  });

  return {
    current,
    stateWord,
    refresh,
    working: () => phase === "working",
    /** A step is a plan made at turn start, shown only while that turn runs; an ask outlives its turn. */
    detail: () => (phase === "working" ? doing : ask),
    /** Whether the detail is the finished turn's ask rather than the running step. */
    asking: () => phase !== "working" && ask !== undefined,
    reply: () => reply,
    /** Drops the draft once you type: it only answers an empty editor. */
    dropReply: () => {
      reply = undefined;
    },
    /** The draft to insert, at most once: a second tab is pi's own again. */
    takeReply: () => {
      const draft = reply;
      reply = undefined;
      if (draft) {
        offered = false;
        unusedReplies = 0;
        backedOff = 0;
        paint();
      }
      return draft;
    },
    /** Called whenever an async reading changes what the label shows. */
    onChange: (listener: () => void) => {
      changed = listener;
    },
  };
};

export type LabelState = ReturnType<typeof createLabel>;
