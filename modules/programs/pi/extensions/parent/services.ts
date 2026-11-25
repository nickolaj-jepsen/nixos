/**
 * What parent features share, built once per load before any feature
 * registers, so every handler a service registers runs ahead of the features'
 * own handlers for the same event.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createIdentity } from "./identity.ts";
import { createEditorHooks, publishEditorHooks } from "./lib/editor-hooks.ts";
import { createUserWait } from "./lib/user-wait.ts";

export const createServices = (pi: ExtensionAPI) => {
  const userWait = createUserWait(pi);
  const editorHooks = createEditorHooks();
  // Spellfix's decorator lives in an agents package that can't import this module.
  publishEditorHooks(pi, editorHooks);
  return {
    userWait,
    identity: createIdentity(pi, userWait),
    editorHooks,
  };
};

export type Services = ReturnType<typeof createServices>;
