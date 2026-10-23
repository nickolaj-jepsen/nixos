import type { Action, ChromeState } from "./state.ts";

/** Runs one of pi's own keybinding actions, or names the key when the editor has none. */
const appAction =
  (state: ChromeState, id: string, key: string): Action =>
  (ctx) => {
    const handler = state.editor?.actionHandlers?.get(id);
    if (handler) handler();
    else ctx.ui.notify(`chrome: press ${key}`, "info");
  };

export const createActions = (state: ChromeState) => {
  const openModels = appAction(state, "app.model.select", "ctrl+l");
  let pickerOpen = false;

  return {
    // A second click closes the picker; a picker is open while focus has left the prompt.
    model: ((ctx) => {
      const focus = state.tui?.getFocusedComponent?.();
      if (pickerOpen && focus && focus !== state.editorComponent) {
        (focus as { handleInput?(data: string): void }).handleInput?.("\x1b");
        pickerOpen = false;
        return;
      }
      pickerOpen = true;
      return openModels(ctx);
    }) as Action,
    effort: appAction(state, "app.thinking.cycle", "shift+tab"),
  };
};
