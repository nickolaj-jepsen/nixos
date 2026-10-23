/**
 * The frame around pi's editor: the top border names the session, the footer
 * shows the model, spend and git. Modules live in `chrome/`; pi loads only
 * top-level files, so this is the one entry point.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createActions } from "./chrome/actions.ts";
import { createEditorChrome } from "./chrome/editor.ts";
import { createFooter } from "./chrome/footer.ts";
import { measurementLevels } from "./chrome/measurements.ts";
import { createIdentity } from "./chrome/identity.ts";
import { createState } from "./chrome/state.ts";

export default function (pi: ExtensionAPI) {
  const state = createState();
  const actions = createActions(state);
  const identity = createIdentity(pi, state);
  const footer = createFooter(pi, state, actions);
  const editor = createEditorChrome(state, {
    top: (width, hidden, border) =>
      identity.drawTop(width, hidden, border, measurementLevels(state, footer.meters())),
  });

  // Spellfix installs its editor from its own session_start; wrap it once every startup handler ran.
  pi.on("session_start", (_event, ctx) => {
    setTimeout(() => {
      if (state.ctx === ctx) editor.ensureInstalled(ctx);
    }, 0).unref?.();
  });
  // Leave the terminal's pointer as it was.
  pi.on("session_shutdown", () => state.setHover(undefined));
  // A second chance, in case an editor was installed late.
  pi.on("agent_start", (_event, ctx) => editor.ensureInstalled(ctx));
}
