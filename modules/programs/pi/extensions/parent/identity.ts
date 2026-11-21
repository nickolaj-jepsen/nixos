/**
 * What the session is called and whether its last turn failed; chrome's
 * border and title paint them.
 *
 * The label is the session's name, set by `/name`; an unnamed session has none.
 * agent-hub
 * reads the turn's end from the registry entry `claude-peers.ts` writes, which asks this
 * for the failure and whether a peer woke the turn.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { oneLine } from "../shared/naming.ts";
import { PEER_MESSAGE_TYPE } from "./claude-peers/protocol.ts";
import type { UserWait } from "./lib/user-wait.ts";

export type Label = {
  text: string;
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
  const listeners = new Set<() => void>();

  const paint = () => {
    for (const listener of listeners) listener();
  };

  const current = (): Label | undefined => {
    const name = pi.getSessionName();
    return name ? { text: name } : undefined;
  };

  // Sub-agent widgets already own `●`, `○`, `⟳` and `▸`, so states that need you
  // are words and "working" is either pi's spinner or a frozen frame of one.
  const stateWord = (ctx: ExtensionContext) => {
    if (userWait.waitingOnUser(ctx)) return "waiting";
    if (working) return "";
    return failed ? "failed" : "";
  };

  pi.on("session_start", () => {
    working = false;
    failed = "";
    peerTurn = false;
  });

  pi.on("before_agent_start", (event) => {
    failed = "";
    peerTurn = event.messageType === "custom" && event.message.customType === PEER_MESSAGE_TYPE;
  });

  pi.on("agent_start", () => {
    working = true;
    paint();
  });

  pi.on("message_end", (event) => {
    if (event.message.role !== "assistant") return;
    if (event.message.stopReason === "error")
      failed = oneLine(event.message.errorMessage ?? "") || "API error";
  });

  pi.on("agent_settled", () => {
    working = false;
    paint();
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
