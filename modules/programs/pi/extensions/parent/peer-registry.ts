/** Optional agent-hub fields for the standalone agents claude-peers plugin. */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Services } from "./services.ts";

const REQUEST = "agents:claude-peers:registry-request";
const METADATA = "agents:claude-peers:registry-metadata";

export default function peerRegistry(pi: ExtensionAPI, { identity, userWait }: Services) {
  let settled = true;
  let ctx: ExtensionContext | undefined;
  let endApproval: (() => void) | undefined;
  const publish = () => {
    pi.events.emit(METADATA, {
      protocol: 1,
      metadata: {
        hubFailed: settled ? identity.failure() : undefined,
        hubPeer: !settled && identity.peerTurn() ? true : undefined,
        hubHidden: process.env.AGENT_HUB_HIDDEN === "1" ? true : undefined,
        tmux: process.env.TMUX_PANE || undefined,
      },
    });
  };
  const unsubscribe = pi.events.on(REQUEST, (event) => {
    if ((event as { protocol?: unknown } | undefined)?.protocol === 1) publish();
  });
  const unsubscribeApproval = pi.events.on("agents:claude-peers:approval-state", (event) => {
    const state = event as { protocol?: unknown; waiting?: unknown } | undefined;
    if (state?.protocol !== 1) return;
    if (state.waiting === true && ctx) endApproval ??= userWait.beginAgentPrompt(ctx);
    else if (state.waiting === false) {
      endApproval?.();
      endApproval = undefined;
    }
  });
  pi.on("session_start", (_event, current) => {
    ctx = current;
    settled = true;
    publish();
  });
  pi.on("agent_start", () => {
    settled = false;
    publish();
  });
  pi.on("agent_settled", () => {
    settled = true;
    publish();
  });
  pi.on("session_shutdown", () => {
    endApproval?.();
    endApproval = undefined;
    ctx = undefined;
    unsubscribe();
    unsubscribeApproval();
  });
}
