import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { Action, ChromeState } from "./state.ts";

/** Runs one of pi's own keybinding actions, or names the key when the editor has none. */
const appAction =
  (state: ChromeState, id: string, key: string): Action =>
  (ctx) => {
    const handler = state.editor?.actionHandlers?.get(id);
    if (handler) handler();
    else ctx.ui.notify(`chrome: press ${key}`, "info");
  };

/**
 * Dispatches a slash command through pi's own command path: the only supported
 * way for one extension to open another's UI. Ignored while focus is elsewhere,
 * where a dispatched command would stack a second overlay on the open one.
 */
const command =
  (state: ChromeState, pi: ExtensionAPI, text: string): Action =>
  () => {
    const focus = state.tui?.getFocusedComponent?.();
    if (focus && focus !== state.editorComponent) return;
    pi.sendUserMessage(text, { expandPromptTemplates: true });
  };

/**
 * Sends Escape to whatever holds focus: how a chrome control that opened an
 * overlay closes it, the same way the overlay's own keys would.
 */
const dismissOverlay =
  (state: ChromeState): Action =>
  () => {
    const focus = state.tui?.getFocusedComponent?.();
    if (!focus || focus === state.editorComponent) return;
    (focus as { handleInput?(data: string): void }).handleInput?.("\x1b");
  };

export const createActions = (pi: ExtensionAPI, state: ChromeState) => {
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
    backgroundTasks: command(state, pi, "/tasks"),
    dismissBackgroundTasks: dismissOverlay(state),
    agents: command(state, pi, "/agents"),
  };
};
