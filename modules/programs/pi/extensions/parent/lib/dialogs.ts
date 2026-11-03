/**
 * The dialogs open on the agent's behalf, each as a one-line label of what it
 * asks: what the registry entry and the hub say the session waits on. Permission
 * prompts report themselves, and a tool's own dialog goes through `during`. A
 * finished run closes whatever is left.
 *
 * A wait that outlives the run that started it has a second source: `hold`, for
 * a feature that is still busy after the agent settled, such as a review the
 * owner is reading. A settled run does not clear it, because it is not a dialog.
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
  // Feature key → the label it keeps until it clears it; a settled run leaves these alone.
  const standing = new Map<string, string>();
  let ownDialogs = 0;
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
    standing.clear();
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
    standing.clear();
  });

  return {
    /** The label of the dialog the session waits on, or undefined when none is open. */
    current: (): string | undefined => open.values().next().value,
    /**
     * Holds `label` as the session's wait reason under `key` until the feature
     * clears it; `undefined` clears it. Unlike `during`, a settled run keeps it.
     */
    hold: (key: string, label: string | undefined): void => {
      const text = label === undefined ? undefined : clip(oneLine(label), LABEL_MAX);
      if (text === undefined) {
        if (standing.delete(key)) notify();
        return;
      }
      if (standing.get(key) === text) return;
      standing.set(key, text);
      notify();
    },
    /** The standing label a feature holds, if any: what the session waits on after a dialog closes. */
    standing: (): string | undefined => standing.values().next().value,
    /** Counts `label` as a dialog the session waits on until `run` settles. */
    during: async <T>(label: string, run: () => Promise<T>): Promise<T> => {
      const id = `own-${ownDialogs++}`;
      open.set(id, clip(oneLine(label), LABEL_MAX));
      notify();
      try {
        return await run();
      } finally {
        if (open.delete(id)) notify();
      }
    },
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
