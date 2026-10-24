/**
 * The frame around pi's editor: the top border names the session, the footer
 * shows the model, spend and git. Modules live in `chrome/`; pi loads only
 * top-level files, so this is the one entry point.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { ensurePromptEditor, unwrapPromptEditor, wrapPromptEditor } from "./lib/prompt-editor.ts";
import { createActions } from "./chrome/actions.ts";
import { createBorder } from "./chrome/border.ts";
import { createEditorChrome } from "./chrome/editor.ts";
import { createFooter } from "./chrome/footer.ts";
import { createLabel } from "./chrome/label.ts";
import { measurementLevels } from "./chrome/measurements.ts";
import { createState } from "./chrome/state.ts";
import { createTitle } from "./chrome/title.ts";

export default function (pi: ExtensionAPI) {
  const state = createState();
  // Registered before the modules, so their handlers already see the session. pi
  // builds a fresh runtime, and so a fresh instance of this, for every session.
  pi.on("session_start", (_event, ctx) => {
    state.ctx = ctx;
    state.live = ctx.mode === "tui" && ctx.hasUI;
  });
  const actions = createActions(pi, state);
  const label = createLabel(pi, state);
  // After the label, so its handlers read the turn state the label just updated.
  createTitle(pi, state, label);
  const border = createBorder(state, label);
  const footer = createFooter(pi, state, actions);
  const wrapper = createEditorChrome(state, {
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
  });

  // Per live session under one key, so no earlier session's wrapper draws through its dead ctx.
  pi.on("session_start", (_event, ctx) => {
    if (state.live) wrapPromptEditor("chrome", wrapper);
    ensurePromptEditor(ctx);
  });
  pi.on("session_shutdown", () => {
    state.tui = undefined;
    unwrapPromptEditor("chrome", wrapper);
  });
  // A second chance, in case another extension installed a factory of its own late.
  pi.on("agent_start", (_event, ctx) => ensurePromptEditor(ctx));
}
