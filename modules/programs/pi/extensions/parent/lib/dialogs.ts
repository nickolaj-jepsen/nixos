/**
 * The permission dialogs open on the agent's behalf, each as a one-line label of
 * the call it asks about: what the registry entry and the hub say the session
 * waits on. A finished run closes whatever is left.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  PERMISSIONS_DECISION_CHANNEL,
  PERMISSIONS_UI_PROMPT_CHANNEL,
  type PermissionDecisionEvent,
  type PermissionUiPromptEvent,
} from "@gotgenes/pi-permission-system";
import { clip, oneLine } from "../../shared/naming.ts";

// As the hub's own cap on a label.
const LABEL_MAX = 200;

export const createDialogs = (pi: ExtensionAPI) => {
  // Request id → label, in the order they opened; the first is the one shown.
  const open = new Map<string, string>();
  const listeners = new Set<() => void>();
  let offs: (() => void)[] = [];

  const notify = () => {
    for (const listener of listeners) listener();
  };
  const unsubscribe = () => {
    for (const off of offs) off();
    offs = [];
  };

  const onPrompt = (data: unknown) => {
    const event = data as PermissionUiPromptEvent;
    const what = `${event.request?.toolName ?? event.surface ?? "permission"}: ${event.value ?? ""}`;
    const requester = event.forwarding?.requesterAgentName;
    const label = oneLine(requester ? `${requester} · ${what}` : what);
    open.set(event.requestId, clip(label, LABEL_MAX));
    notify();
  };

  const onDecision = (data: unknown) => {
    if (open.delete((data as PermissionDecisionEvent).requestId)) notify();
  };

  pi.on("session_start", () => {
    unsubscribe();
    open.clear();
    offs = [
      pi.events.on(PERMISSIONS_UI_PROMPT_CHANNEL, onPrompt),
      pi.events.on(PERMISSIONS_DECISION_CHANNEL, onDecision),
    ];
  });
  pi.on("agent_settled", () => {
    if (open.size === 0) return;
    open.clear();
    notify();
  });
  pi.on("session_shutdown", () => {
    unsubscribe();
    open.clear();
  });

  return {
    /** The label of the dialog the session waits on, or undefined when none is open. */
    current: (): string | undefined => open.values().next().value,
    /** Calls `listener` whenever a dialog opens or closes; returns the unsubscribe. */
    onChange: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
};

export type Dialogs = ReturnType<typeof createDialogs>;
