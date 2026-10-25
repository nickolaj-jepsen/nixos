import type {
  AppKeybinding,
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import type { Git } from "./git.ts";
import type { Menu } from "./menu.ts";
import { createMenuPopper } from "./menu.ts";
import { gitMenu } from "./links.ts";
import { folderMenu } from "./places.ts";
import type { Action, ChromeState, ClickAt } from "./state.ts";

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

export const createActions = (pi: ExtensionAPI, state: ChromeState, git: Git) => {
  const openModels = command(state, pi, "/models");
  const closeOverlay = dismissOverlay(state);
  const menus = createMenuPopper();
  // Building the git menu asks git and gh, so a double click could queue a second
  // one behind the first; the build is the slow half, not the popover.
  let building = false;

  const show = async (ctx: ExtensionContext, build: () => Menu | Promise<Menu>, at?: ClickAt) => {
    // The footer is how a popover is dismissed: an overlay never reports a click
    // outside itself, so the control that opened it closes it.
    if (menus.isOpen()) {
      menus.close();
      return;
    }
    // Only the build is guarded: a second click while git answers must not queue
    // another lookup, but the open menu has to stay reachable above.
    if (building) return;
    building = true;
    let menu: Menu;
    try {
      menu = await build();
    } finally {
      building = false;
    }
    await menus.open(ctx, menu, at);
  };

  /**
   * The path is the checkout the session works in, so its menu opens the place
   * the work continues rather than acting on the first click: the footer sits one
   * row under the shell prompt, and a stray click there used to start an editor.
   */
  const folder = ((ctx, at) => show(ctx, () => folderMenu(ctx.cwd), at)) as Action;

  const gitLinks = ((ctx, at) => {
    const snapshot = git.snapshot();
    // Undefined is the first status still in flight, not a missing repository.
    if (!snapshot) {
      ctx.ui.notify("chrome: git status is still loading", "warning");
      return;
    }
    if (!snapshot.state) {
      ctx.ui.notify("chrome: this directory is not a git repository", "warning");
      return;
    }
    const repo = { ...snapshot, state: snapshot.state };
    return show(ctx, () => gitMenu(ctx, repo), at);
  }) as Action;

  return {
    folder,
    git: gitLinks,
    // The picker is this repo's own (/models: labels, cost, context). A click while
    // it or any other dialog holds focus closes that instead of stacking the
    // picker on top: pi closes those on Escape without telling anyone.
    model: ((ctx) => {
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
    memory: command(state, pi, "/memory"),
    // A full window is where the session tree earns its keep, so the context pill
    // opens it. pi's own handler, not the slash command: /tree is a built-in that
    // only the interactive input path runs, while sendUserMessage would hand the
    // text to the model as a prompt. /cost above is an extension command, which is
    // why that one can go through the command path.
    tree: appAction(state, "app.session.tree", "alt+shift+t"),
  };
};
