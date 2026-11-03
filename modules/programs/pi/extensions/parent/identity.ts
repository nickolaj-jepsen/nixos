/**
 * The session's label and what the last turn wants from you, as agent-hub reads
 * them (`lib/hub.ts`); chrome's border and title paint them, and the record is
 * persisted on the branch (`shared/identity.ts`) so a resumed session paints at
 * once and `/resume` and memory have something to go on.
 *
 * The hub makes one reading at each substantive turn start, beside the run, and
 * one when the turn settles; pi runs both with its own side model when the hub
 * asks. The hub reads the session file itself; this side tells it where each turn
 * starts and ends, and keeps what is pi's alone: the session name, which follows
 * the label until you run `/name`, and the drafted reply on the input line, which
 * backs off when you keep passing it over.
 *
 * Without the hub the label is the first request cut to a name.
 */
import { contentText } from "@earendil-works/pi-ai";
import {
  copyToClipboard,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { IDENTITY_ENTRY, type IdentityRecord, readIdentity } from "../shared/identity.ts";
import { firstRequest, NAME_TIMEOUT_MS, oneLine, stripRequest } from "../shared/naming.ts";
import { sideCall } from "../shared/side-call.ts";
import { PEER_MESSAGE_TYPE } from "./claude-peers/protocol.ts";
import type { Hub } from "./lib/hub.ts";
import type { UserWait } from "./lib/user-wait.ts";

type Source = "name" | "model" | "prompt";

export type Label = {
  text: string;
  source: Source;
};

const SHORTCUT = "alt+r";
const MAX_LABEL_CHARS = 40;
// The peers note is part of the system prompt, so the run waits for it; a hub slower than this goes without.
const PEERS_TIMEOUT_MS = 500;
// Drafts passed over this many turns running are noise; from then on only every
// few turns gets one, until one is taken.
const REPLY_BACKOFF_AFTER = 4;
const REPLY_BACKOFF_EVERY = 3;

const cut = (text: string) => {
  const line = oneLine(text);
  if (line.length <= MAX_LABEL_CHARS) return line;
  const head = line.slice(0, MAX_LABEL_CHARS);
  const lastSpace = head.lastIndexOf(" ");
  return `${(lastSpace > 20 ? head.slice(0, lastSpace) : head).trim()}…`;
};

/** The background jobs bg_run has running, which a turn that ends to wait on them counts on. */
export type Jobs = { running: () => number };

/**
 * Registers the identity's handlers, `/header` and its shortcut. Create it
 * before any feature whose handlers read it on the same event.
 */
export const createIdentity = (pi: ExtensionAPI, userWait: UserWait, hub: Hub, jobs: Jobs) => {
  let session: ExtensionContext | undefined;
  /** The record last persisted on the branch. */
  let record: IdentityRecord = {};
  let working = false;
  /** Whether the run ended on an error, for a hub that cannot say so itself. */
  let errored = false;
  const listeners = new Set<() => void>();
  let peers: Promise<string | undefined> = Promise.resolve(undefined);
  /** The draft on offer, and the ask it answers, so one row pushed twice offers it once. */
  let reply: string | undefined;
  let replyFor: string | undefined;
  let offered = false;
  let unusedReplies = 0;
  let backedOff = 0;

  const paint = () => {
    for (const listener of listeners) listener();
  };

  /** A session name we did not write is the person's choice through `/name`, and it outranks the label. */
  const explicitName = () => {
    const name = pi.getSessionName();
    return name && name !== record.autoName ? name : undefined;
  };

  /** The first request cut to a name, by leaf: every repaint asks while the hub is away. */
  let fallback: { leaf: string | null; text: string } | undefined;

  const current = (ctx: ExtensionContext): Label | undefined => {
    const name = explicitName();
    if (name) return { text: name, source: "name" };
    // `adopt` copies each hub reading into the record before anything repaints.
    if (record.text) return { text: record.text, source: "model" };
    if (hub.connected()) return undefined;
    const leaf = ctx.sessionManager.getLeafId();
    if (fallback?.leaf !== leaf)
      fallback = { leaf, text: cut(stripRequest(firstRequest(ctx) ?? "")) };
    return fallback.text ? { text: fallback.text, source: "prompt" } : undefined;
  };

  /**
   * Persists what the hub says the session is called and, unless you named it,
   * renames it to match: `/resume` lists sessions by name, the one place the label
   * helps before the window is even open.
   */
  const adopt = () => {
    const identity = hub.identity();
    if (!identity || !session) return;
    const next: IdentityRecord = {
      text: identity.label ?? record.text,
      calls: identity.calls ?? record.calls,
      summary: identity.summary ?? record.summary,
      tags: identity.tags ?? record.tags,
      autoName: record.autoName,
    };
    const rename = !!next.text && !explicitName() && pi.getSessionName() !== next.text;
    if (rename) next.autoName = next.text;
    // The count moves before each reading lands; it rides along with the next real change.
    const changed =
      JSON.stringify({ ...next, calls: 0 }) !== JSON.stringify({ ...record, calls: 0 });
    // Recorded before the rename, whose session_info_changed reads it to tell our name from yours.
    record = next;
    if (!changed) return;
    pi.appendEntry<IdentityRecord>(IDENTITY_ENTRY, record);
    if (rename && next.text) pi.setSessionName(next.text);
  };

  /**
   * The draft to offer for a new ask, if any. After enough untaken drafts in a
   * row, only every few turns gets one: a row you keep reading past is clutter.
   */
  const offer = () => {
    const row = hub.read();
    const ask = row?.state === "needs-reply" ? row.ask : undefined;
    if (ask === replyFor) return;
    replyFor = ask;
    reply = undefined;
    if (!ask || !row?.reply) return;
    if (unusedReplies >= REPLY_BACKOFF_AFTER && ++backedOff % REPLY_BACKOFF_EVERY !== 0) return;
    offered = true;
    reply = row.reply;
  };

  hub.onChange(() => {
    adopt();
    offer();
    paint();
  });
  hub.attachWith(() => ({
    record: { label: record.text, summary: record.summary, tags: record.tags, calls: record.calls },
    name: explicitName(),
  }));
  hub.judgeWith(async (request) => {
    const ctx = session;
    if (!ctx) return undefined;
    const result = await sideCall(pi, ctx, {
      source: request.source,
      system: request.system,
      prompt: request.prompt,
      maxTokens: request.maxTokens,
      // A few short lines, and nothing worth thinking about: a model that reasons
      // here spends the whole budget on it and returns no text at all.
      reasoning: "minimal",
      timeoutMs: NAME_TIMEOUT_MS,
      signal: request.signal,
    });
    return "error" in result ? undefined : result.text;
  });

  // Sub-agent widgets already own `●`, `○`, `⟳` and `▸`, so states that need you
  // are words and "working" is either pi's spinner or a frozen frame of one.
  const stateWord = (ctx: ExtensionContext) => {
    if (userWait.waitingOnUser(ctx)) return "waiting";
    if (working) return "";
    const state = hub.read()?.state;
    if (state === "failed" || (state === undefined && errored)) return "failed";
    return state === "needs-reply" ? "needs you" : "";
  };

  const quote = (path: string) =>
    /^[a-zA-Z0-9_\-./~:@]+$/.test(path) ? path : `'${path.replace(/'/g, `'\\''`)}'`;
  const sessionId = (ctx: ExtensionContext) => ctx.sessionManager.getSessionId();
  const resumeCommand = (ctx: ExtensionContext) =>
    `cd ${quote(ctx.cwd)} && pi --session ${sessionId(ctx).slice(0, 8)}`;

  const relabel = async (ctx: ExtensionContext) => {
    if (!hub.relabel()) ctx.ui.notify("identity: agent-hub is not running", "warning");
  };

  const summary = (ctx: ExtensionContext) => {
    const shown = current(ctx);
    const row = hub.read();
    const persisted = ctx.sessionManager.getSessionFile();
    return [
      `${shown?.text ?? "(unnamed)"}  (${shown?.source ?? "none"})`,
      record.summary,
      record.tags?.length ? `tags: ${record.tags.join(", ")}` : undefined,
      row?.doing ? `doing: ${row.doing}` : undefined,
      row?.ask ? `needs: ${row.ask}` : undefined,
      reply ? `reply: ${reply}` : undefined,
      row ? `hub: ${row.state}` : "hub: not connected",
      `path: ${ctx.cwd}`,
      persisted
        ? `session: ${sessionId(ctx)}`
        : "session: ephemeral (--no-session), nothing to resume",
      `label calls: ${record.calls ?? 0}`,
      persisted ? `resume: ${resumeCommand(ctx)}` : undefined,
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
      if (choice === "Refresh label now") await relabel(ctx);
      else if (choice === "Copy resume command") {
        if (!ctx.sessionManager.getSessionFile()) {
          ctx.ui.notify("identity: this session is ephemeral (--no-session)", "warning");
          return;
        }
        await copyToClipboard(resumeCommand(ctx));
        ctx.ui.notify("identity: resume command copied", "info");
      }
    },
  });

  pi.registerShortcut(SHORTCUT, {
    description: "Relabel this session now",
    handler: (ctx) => relabel(ctx),
  });

  pi.on("session_start", (_event, ctx) => {
    session = ctx;
    record = {};
    working = false;
    errored = false;
    reply = undefined;
    replyFor = undefined;
    fallback = undefined;
    // The last persisted record on this branch wins, so a resumed session paints
    // instantly and the hub starts from it.
    for (const entry of ctx.sessionManager.getBranch()) {
      const data = readIdentity(entry);
      if (data)
        record = {
          ...record,
          ...Object.fromEntries(Object.entries(data).filter(([, v]) => v !== undefined)),
        };
    }
  });

  pi.on("session_info_changed", () => {
    hub.named(explicitName());
  });

  // The turn's request is new information, and the reading runs beside the run
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
    reply = undefined;
    errored = false;
    peers = hub.turnStart(
      event.messageType === "user" ? event.prompt : contentText(event.message.content, "\n"),
      event.messageType === "user",
      event.messageType === "custom" && event.message.customType === PEER_MESSAGE_TYPE,
      pi.getActiveTools().includes("enter_worktree"),
      PEERS_TIMEOUT_MS,
    );
  });

  pi.on("agent_start", () => {
    working = true;
    paint();
  });

  pi.on("message_end", (event) => {
    if (event.message.role === "assistant" && event.message.stopReason === "error") errored = true;
  });

  pi.on("agent_settled", () => {
    working = false;
    paint();
    // Every turn is read, however short: a short one can still end on a question.
    hub.turnEnd(jobs.running(), errored);
  });

  pi.on("session_shutdown", () => {
    session = undefined;
  });

  return {
    current,
    stateWord,
    refresh: relabel,
    working: () => working,
    /** A step is a plan made at turn start, shown only while that turn runs; an ask outlives its turn. */
    detail: () => {
      const row = hub.read();
      return working
        ? row?.doing || undefined
        : row?.state === "needs-reply"
          ? row.ask || undefined
          : undefined;
    },
    /** Whether the detail is the finished turn's ask rather than the running step. */
    asking: () => !working && hub.read()?.state === "needs-reply" && !!hub.read()?.ask,
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
    /** The note on the other sessions in this working tree, for the turn starting now. */
    peers: () => peers,
    /** The hub's sentence about the session, persisted across reloads. */
    summary: () => record.summary,
    /** Whether `name` is the session name identity wrote, not one the user chose with `/name`. */
    isAutoName: (name: string | undefined) => name !== undefined && name === record.autoName,
    /** Calls `listener` whenever the hub's reading changes what the label shows. */
    onChange: (listener: () => void) => {
      listeners.add(listener);
    },
  };
};

export type Identity = ReturnType<typeof createIdentity>;
