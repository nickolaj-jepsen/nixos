/**
 * What the review modules share: the extension, the chrome state, the two
 * services the review reports through, and the string a half-built module
 * says instead of acting.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { ChromeState } from "../chrome/state.ts";
import type { Services } from "../services.ts";

export type ReviewEnv = {
  pi: ExtensionAPI;
  state: ChromeState;
  dialogs: Services["dialogs"];
  hub: Services["hub"];
};

/** Until a module is filled in, every branch says this and returns. */
export const NOT_YET = "review: not implemented yet";

export const notYet = (ctx: ExtensionContext) => ctx.ui.notify(NOT_YET, "info");
