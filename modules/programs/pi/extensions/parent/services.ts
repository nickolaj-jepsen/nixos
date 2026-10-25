/**
 * What parent features share, built once per load before any feature
 * registers, so every handler a service registers runs ahead of the features'
 * own handlers for the same event.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createIdentity } from "./identity.ts";
import { createEditorHooks } from "./lib/editor-hooks.ts";
import { createModelsPicker } from "./lib/models-picker.ts";
import { createUserWait } from "./lib/user-wait.ts";

export const createServices = (pi: ExtensionAPI) => {
  const userWait = createUserWait(pi);
  return {
    userWait,
    identity: createIdentity(pi, userWait),
    editorHooks: createEditorHooks(),
    modelsPicker: createModelsPicker(),
  };
};

export type Services = ReturnType<typeof createServices>;
