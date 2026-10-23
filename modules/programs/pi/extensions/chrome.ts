/**
 * The frame around pi's editor: the top border names the session, the footer
 * shows the model, spend and git. Modules live in `chrome/`; pi loads only
 * top-level files, so this is the one entry point.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { ensurePromptEditor, wrapPromptEditor } from "./lib/prompt-editor.ts";
import { createActions } from "./chrome/actions.ts";
import { createEditorChrome } from "./chrome/editor.ts";
import { createFooter } from "./chrome/footer.ts";
import { measurementLevels } from "./chrome/measurements.ts";
import { createIdentity } from "./chrome/identity.ts";
import { createState } from "./chrome/state.ts";

export default function (pi: ExtensionAPI) {
  const state = createState();
  // Registered before the modules, so their handlers already see the session. pi
  // builds a fresh runtime, and so a fresh instance of this, for every session.
  pi.on("session_start", (_event, ctx) => {
    state.ctx = ctx;
    state.live = ctx.mode === "tui" && ctx.hasUI;
  });
  const actions = createActions(pi, state);
  const identity = createIdentity(pi, state);
  const footer = createFooter(pi, state, actions);
  wrapPromptEditor(
    createEditorChrome(state, {
      top: (width, hidden, border, status) =>
        identity.drawTop(
          width,
          hidden,
          border,
          status,
          measurementLevels(state, footer.measurements()),
        ),
    }),
  );

  pi.on("session_start", (_event, ctx) => ensurePromptEditor(ctx));
  // A second chance, in case another extension installed a factory of its own late.
  pi.on("agent_start", (_event, ctx) => ensurePromptEditor(ctx));
}
