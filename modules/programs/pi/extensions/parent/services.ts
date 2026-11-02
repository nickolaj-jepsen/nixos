/**
 * What parent features share, built once per load before any feature
 * registers, so every handler a service registers runs ahead of the features'
 * own handlers for the same event.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createIdentity, type Jobs } from "./identity.ts";
import { createDialogs } from "./lib/dialogs.ts";
import { createEditorHooks } from "./lib/editor-hooks.ts";
import { createHub } from "./lib/hub.ts";
import { createUserWait } from "./lib/user-wait.ts";

export const createServices = (pi: ExtensionAPI) => {
  const userWait = createUserWait(pi);
  // Before the hub and the identity: a run's end closes its dialogs before it reports the turn.
  const dialogs = createDialogs(pi);
  const hub = createHub(pi, dialogs);
  // bg.ts supplies the count.
  const jobs: Jobs = { running: () => 0 };
  return {
    userWait,
    dialogs,
    hub,
    jobs,
    identity: createIdentity(pi, userWait, hub, jobs),
    editorHooks: createEditorHooks(),
  };
};

export type Services = ReturnType<typeof createServices>;
