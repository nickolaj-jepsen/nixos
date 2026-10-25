/**
 * The frame around pi's editor: the top border names the session, the footer
 * shows the model, spend and git. Modules live in `chrome/`.
 */
import type { ExtensionAPI, ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { createActions } from "./chrome/actions.ts";
import { createBorder } from "./chrome/border.ts";
import { PromptEditor, type Painters } from "./chrome/editor.ts";
import { createFooter } from "./chrome/footer.ts";
import { measurementLevels } from "./chrome/measurements.ts";
import { createState } from "./chrome/state.ts";
import { createTitle } from "./chrome/title.ts";
import type { Services } from "./services.ts";

// pi's root types omit EditorFactory, so it comes from the one API that takes it.
type EditorFactory = NonNullable<Parameters<ExtensionUIContext["setEditorComponent"]>[0]>;

export default function (
  pi: ExtensionAPI,
  { identity, userWait, editorHooks, modelsPicker }: Services,
) {
  const state = createState();
  // Registered before the modules, so their handlers already see the session. pi
  // builds a fresh runtime, and so a fresh instance of this, for every session.
  pi.on("session_start", (_event, ctx) => {
    state.ctx = ctx;
    state.live = ctx.mode === "tui" && ctx.hasUI;
  });
  const actions = createActions(pi, state, modelsPicker);
  identity.onChange(() => state.tui?.requestRender());
  createTitle(pi, state, identity, userWait);
  const border = createBorder(state, identity);
  const footer = createFooter(pi, state, actions);
  const painters: Painters = {
    top: (width, hidden, color, status) =>
      border.drawTop(
        width,
        hidden,
        color,
        status,
        measurementLevels(state, footer.measurements(), {
          tools: actions.tools,
          thinking: actions.thinking,
          tree: actions.tree,
          // pi owns this flag and alt+t writes it; asking costs a settings clone per
          // border render, which the measurements beside it already outweigh.
          thinkingOpen: !pi.getSettings().hideThinkingBlock,
        }),
      ),
    hint: border.hint,
    takeHint: border.takeHint,
  };
  const factory: EditorFactory = (tui, theme, keybindings) => {
    const editor = new PromptEditor(tui, theme, keybindings, state, painters, editorHooks);
    state.tui = tui;
    state.editor = editor;
    return editor;
  };

  // pi puts its default editor back when a session ends, so this installs once per session.
  pi.on("session_start", (_event, ctx) => {
    if (state.live && ctx.ui.getEditorComponent() !== factory) ctx.ui.setEditorComponent(factory);
  });
  pi.on("session_shutdown", () => {
    // Until pi swaps it out, the editor draws plainly rather than through a dead ctx.
    state.live = false;
    state.tui = undefined;
    state.editor = undefined;
  });
}
