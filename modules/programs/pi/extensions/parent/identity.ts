/**
 * What the session is called and whether its last turn wants you; chrome's
 * border and title paint them.
 *
 * The label is the session's name, else the first request cut to a name. A
 * session with no name gets one after its first turn, from one side call, as
 * Claude Code titles its own; `/name` replaces it. This side tells agent-hub
 * (`lib/hub.ts`) where each turn starts and ends, and paints the state the hub's
 * row reports back.
 */
import { contentText } from "@earendil-works/pi-ai";
import {
  copyToClipboard,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { firstRequest, oneLine, stripRequest } from "../shared/naming.ts";
import { sideCall } from "../shared/side-call.ts";
import { ENTER_WORKTREE } from "../shared/tools.ts";
import { PEER_MESSAGE_TYPE } from "./claude-peers/protocol.ts";
import type { Hub } from "./lib/hub.ts";
import type { UserWait } from "./lib/user-wait.ts";

type Source = "name" | "prompt";

export type Label = {
  text: string;
  source: Source;
};

const MAX_LABEL_CHARS = 40;
// The peers note is part of the system prompt, so the run waits for it; a hub slower than this goes without.
const PEERS_TIMEOUT_MS = 500;
// As much of the closing words as the hub keeps.
const SAID_MAX = 6000;
// What the title call reads of the first turn, and how long it may take.
const TITLE_READS = 1500;
const TITLE_TIMEOUT_MS = 30_000;
const TITLE_SYSTEM = `Name this coding session in 3 to 6 words, from its first request and the
assistant's reply. Sentence case, no quotes, no trailing period, nothing else. Name the work,
not the person or the assistant: "Footer popup width on narrow terminals".`;

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
 * Registers the identity's handlers and `/header`. Create it before any feature
 * whose handlers read it on the same event.
 */
export const createIdentity = (pi: ExtensionAPI, userWait: UserWait, hub: Hub, jobs: Jobs) => {
  let working = false;
  /** Whether the run ended on an error, for a hub that cannot say so itself. */
  let errored = false;
  /** The run's closing words, for the hub's row. */
  let said = "";
  const listeners = new Set<() => void>();
  let peers: Promise<string | undefined> = Promise.resolve(undefined);
  /** Whether this session has been offered a title: at most one call each. */
  let titled = false;

  const paint = () => {
    for (const listener of listeners) listener();
  };

  /** The first request cut to a name, by leaf: every repaint asks. */
  let fallback: { leaf: string | null; text: string } | undefined;

  const current = (ctx: ExtensionContext): Label | undefined => {
    const name = pi.getSessionName();
    if (name) return { text: name, source: "name" };
    const leaf = ctx.sessionManager.getLeafId();
    if (fallback?.leaf !== leaf)
      fallback = { leaf, text: cut(stripRequest(firstRequest(ctx) ?? "")) };
    return fallback.text ? { text: fallback.text, source: "prompt" } : undefined;
  };

  hub.onChange(paint);
  hub.attachWith(() => ({ name: pi.getSessionName() }));

  // Sub-agent widgets already own `●`, `○`, `⟳` and `▸`, so states that need you
  // are words and "working" is either pi's spinner or a frozen frame of one.
  const stateWord = (ctx: ExtensionContext) => {
    if (userWait.waitingOnUser(ctx)) return "waiting";
    if (working) return "";
    const state = hub.read()?.state;
    return state === "failed" || (state === undefined && errored) ? "failed" : "";
  };

  const quote = (path: string) =>
    /^[a-zA-Z0-9_\-./~:@]+$/.test(path) ? path : `'${path.replace(/'/g, `'\\''`)}'`;
  const sessionId = (ctx: ExtensionContext) => ctx.sessionManager.getSessionId();
  const resumeCommand = (ctx: ExtensionContext) =>
    `cd ${quote(ctx.cwd)} && pi --session ${sessionId(ctx).slice(0, 8)}`;

  const summary = (ctx: ExtensionContext) => {
    const shown = current(ctx);
    const row = hub.read();
    const persisted = ctx.sessionManager.getSessionFile();
    return [
      `${shown?.text ?? "(unnamed)"}  (${shown?.source ?? "none"})`,
      row ? `hub: ${row.state}` : "hub: not connected",
      `path: ${ctx.cwd}`,
      persisted
        ? `session: ${sessionId(ctx)}`
        : "session: ephemeral (--no-session), nothing to resume",
      persisted ? `resume: ${resumeCommand(ctx)}` : undefined,
    ]
      .filter(Boolean)
      .join("\n");
  };

  pi.registerCommand("header", {
    description: "Session identity: show path and id, and copy the resume command",
    handler: async (_args, ctx) => {
      ctx.ui.notify(summary(ctx), "info");
      if (!ctx.sessionManager.getSessionFile()) return;
      await copyToClipboard(resumeCommand(ctx));
      ctx.ui.notify("identity: resume command copied", "info");
    },
  });

  /** Names a session that has none, once, from its first turn; one named meanwhile keeps its name. */
  const title = async (ctx: ExtensionContext) => {
    titled = true;
    const request = stripRequest(firstRequest(ctx) ?? "");
    if (!request) return;
    const result = await sideCall(pi, ctx, {
      source: "session title",
      system: TITLE_SYSTEM,
      prompt: `First request:\n${request.slice(0, TITLE_READS)}\n\nReply:\n${said.slice(0, TITLE_READS)}`,
      maxTokens: 64,
      // A few words: a model that reasons here spends the whole budget on it.
      reasoning: "minimal",
      timeoutMs: TITLE_TIMEOUT_MS,
    });
    const text = "error" in result ? "" : cut(result.text.replace(/^["'`]+|["'`.]+$/g, ""));
    if (text && !pi.getSessionName()) pi.setSessionName(text);
  };

  pi.on("session_start", () => {
    working = false;
    errored = false;
    said = "";
    fallback = undefined;
    titled = false;
  });

  pi.on("session_info_changed", () => {
    hub.named(pi.getSessionName());
  });

  pi.on("before_agent_start", (event) => {
    errored = false;
    peers = hub.turnStart(
      event.messageType === "user" ? event.prompt : contentText(event.message.content, "\n"),
      event.messageType === "user",
      event.messageType === "custom" && event.message.customType === PEER_MESSAGE_TYPE,
      pi.getActiveTools().includes(ENTER_WORKTREE),
      PEERS_TIMEOUT_MS,
    );
  });

  pi.on("agent_start", () => {
    working = true;
    said = "";
    paint();
  });

  pi.on("message_end", (event) => {
    if (event.message.role !== "assistant") return;
    if (event.message.stopReason === "error") errored = true;
    const text = contentText(event.message.content, "\n").trim();
    if (text) said = text.slice(-SAID_MAX);
  });

  pi.on("agent_settled", (_event, ctx) => {
    working = false;
    paint();
    hub.turnEnd(jobs.running(), errored, said);
    // Only an interactive session you started: a test session or a headless run needs no name.
    if (
      !titled &&
      !errored &&
      ctx.hasUI &&
      process.env.AGENT_HUB_HIDDEN !== "1" &&
      !pi.getSessionName()
    )
      void title(ctx);
  });

  return {
    current,
    stateWord,
    working: () => working,
    /** The note on the other sessions in this working tree, for the turn starting now. */
    peers: () => peers,
    /** Calls `listener` whenever what the label or the state word shows may have changed. */
    onChange: (listener: () => void) => {
      listeners.add(listener);
    },
  };
};

export type Identity = ReturnType<typeof createIdentity>;
