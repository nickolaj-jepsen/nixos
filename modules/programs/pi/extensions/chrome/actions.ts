import type { Action, ChromeState } from "./state.ts";

/** Runs one of pi's own keybinding actions, or names the key when the editor has none. */
const appAction =
  (state: ChromeState, id: string, key: string): Action =>
  (ctx) => {
    const handler = state.editor?.actionHandlers?.get(id);
    if (handler) handler();
    else ctx.ui.notify(`chrome: press ${key}`, "info");
  };

export const createActions = (state: ChromeState) => ({
  model: appAction(state, "app.model.select", "ctrl+l"),
  effort: appAction(state, "app.thinking.cycle", "shift+tab"),
});
