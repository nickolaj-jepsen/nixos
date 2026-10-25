import { spawn } from "node:child_process";
import type { AppKeybinding, ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ModelsPicker } from "../lib/models-picker.ts";
import type { Action, ChromeState } from "./state.ts";

/** Runs one of pi's own keybinding actions, or names the key when the editor has none. */
const appAction =
  (state: ChromeState, id: AppKeybinding, key: string): Action =>
  (ctx) => {
    const handler = state.editor?.actionHandlers.get(id);
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
    if (focus && focus !== state.editor) return;
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
    if (!focus || focus === state.editor) return;
    (focus as { handleInput?(data: string): void }).handleInput?.("\x1b");
  };

export const createActions = (pi: ExtensionAPI, state: ChromeState, picker: ModelsPicker) => {
  const openModels = command(state, pi, "/models");
  const closeOverlay = dismissOverlay(state);

  return {
    // The path is the checkout the session works in, so it opens where the work
    // continues rather than in a file manager. Plain `code` focuses a window that
    // already has it open and makes one otherwise.
    openFolder: ((ctx) => {
      const child = spawn("code", [ctx.cwd], { detached: true, stdio: "ignore" });
      child.on("error", () => ctx.ui.notify("chrome: cannot run code", "error"));
      child.unref();
    }) as Action,
    // The picker is this repo's own (/models: labels, cost, context), and a
    // second click closes it. Any other overlay closes instead of opening the
    // picker on top: pi closes those on Escape without telling anyone.
    model: ((ctx) => {
      if (picker.isOpen()) return picker.close();
      const focus = state.tui?.getFocusedComponent?.();
      if (focus && focus !== state.editor) return closeOverlay(ctx);
      return openModels(ctx);
    }) as Action,
    effort: appAction(state, "app.thinking.cycle", "shift+tab"),
    // The two chips on the editor's top border. Both flip a flag pi already owns,
    // so ctrl+o and alt+t keep their meaning and the click reads as one more key.
    tools: ((ctx) => ctx.ui.setToolsExpanded(!ctx.ui.getToolsExpanded())) as Action,
    thinking: appAction(state, "app.thinking.toggle", "alt+t"),
    agents: command(state, pi, "/agents"),
    cost: command(state, pi, "/cost"),
    // A full window is where the session tree earns its keep, so the context pill
    // opens it. pi's own handler, not the slash command: /tree is a built-in that
    // only the interactive input path runs, while sendUserMessage would hand the
    // text to the model as a prompt. /cost above is an extension command, which is
    // why that one can go through the command path.
    tree: appAction(state, "app.session.tree", "alt+shift+t"),
  };
};
