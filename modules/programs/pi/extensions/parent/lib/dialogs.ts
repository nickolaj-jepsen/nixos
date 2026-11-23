/**
 * The dialogs open on the agent's behalf, each as a one-line label of what it
 * asks: what the registry entry says the session waits on. Pi reports every
 * `ctx.ui` prompt it raises, and a finished run closes whatever is left.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { clip, oneLine } from "./format.ts";

// The cap on a label, which the registry carries as `waitingFor`.
const LABEL_MAX = 200;

export const createDialogs = (pi: ExtensionAPI) => {
  // The label of the prompt open now; pi nests them under one start/end pair.
  let label: string | undefined;
  const listeners = new Set<() => void>();

  const notify = () => {
    for (const listener of listeners) listener();
  };
  const clear = () => {
    if (label === undefined) return;
    label = undefined;
    notify();
  };

  pi.on("ui_prompt_start", (event) => {
    label = clip(oneLine(event.title ?? `${event.kind} prompt`), LABEL_MAX);
    notify();
  });
  pi.on("ui_prompt_end", clear);
  pi.on("agent_settled", clear);
  pi.on("session_shutdown", clear);

  return {
    /** The label of the dialog the session waits on, or undefined when none is open. */
    current: (): string | undefined => label,
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
