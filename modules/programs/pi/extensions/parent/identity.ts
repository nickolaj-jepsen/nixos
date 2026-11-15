/**
 * What the session is called and whether its last turn failed; chrome's
 * border and title paint them.
 *
 * The label is the session's name, else the first request cut to a name. A
 * session with no name gets one after its first turn, from one side call, as
 * Claude Code titles its own; `/name` replaces it. agent-hub
 * reads the turn's end from the registry entry `claude-peers.ts` writes, which asks this
 * for the failure and whether a peer woke the turn.
 */
import { contentText } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { firstRequest, oneLine, stripRequest } from "../shared/naming.ts";
import { sideCall } from "../shared/side-call.ts";
import { PEER_MESSAGE_TYPE } from "./claude-peers/protocol.ts";
import type { UserWait } from "./lib/user-wait.ts";

type Source = "name" | "prompt";

export type Label = {
  text: string;
  source: Source;
};

const MAX_LABEL_CHARS = 40;
// As much of the closing words as the title call keeps.
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

/**
 * Registers the identity's handlers. Create it before any feature
 * whose handlers read it on the same event.
 */
export const createIdentity = (pi: ExtensionAPI, userWait: UserWait) => {
  let working = false;
  /** Why the run ended on an error, "" when it did not. */
  let failed = "";
  /** Whether a peer's message woke the turn about to run. */
  let peerTurn = false;
  /** The run's closing words, for the title. */
  let said = "";
  const listeners = new Set<() => void>();
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

  // Sub-agent widgets already own `●`, `○`, `⟳` and `▸`, so states that need you
  // are words and "working" is either pi's spinner or a frozen frame of one.
  const stateWord = (ctx: ExtensionContext) => {
    if (userWait.waitingOnUser(ctx)) return "waiting";
    if (working) return "";
    return failed ? "failed" : "";
  };

  /** Names a session that has none, once, from its first turn; one named meanwhile keeps its name. */
  const title = async (ctx: ExtensionContext) => {
    titled = true;
    const request = stripRequest(firstRequest(ctx) ?? "");
    if (!request) return;
    const result = await sideCall(ctx, {
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
    failed = "";
    peerTurn = false;
    said = "";
    fallback = undefined;
    titled = false;
  });

  pi.on("before_agent_start", (event) => {
    failed = "";
    peerTurn = event.messageType === "custom" && event.message.customType === PEER_MESSAGE_TYPE;
  });

  pi.on("agent_start", () => {
    working = true;
    said = "";
    paint();
  });

  pi.on("message_end", (event) => {
    if (event.message.role !== "assistant") return;
    if (event.message.stopReason === "error")
      failed = oneLine(event.message.errorMessage ?? "") || "API error";
    const text = contentText(event.message.content, "\n").trim();
    if (text) said = text.slice(-SAID_MAX);
  });

  pi.on("agent_settled", (_event, ctx) => {
    working = false;
    paint();
    // Only an interactive session you started: a test session or a headless run needs no name.
    if (
      !titled &&
      !failed &&
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
    /** Why the last turn failed, undefined when it did not. */
    failure: () => failed || undefined,
    /** Whether a peer's message woke the turn that is starting or running. */
    peerTurn: () => peerTurn,
    /** Calls `listener` whenever what the label or the state word shows may have changed. */
    onChange: (listener: () => void) => {
      listeners.add(listener);
    },
  };
};

export type Identity = ReturnType<typeof createIdentity>;
