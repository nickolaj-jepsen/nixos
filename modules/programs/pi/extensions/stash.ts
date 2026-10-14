/**
 * Claude Code's ctrl+s prompt stash: park the draft in the editor, send
 * something else, and get the draft back once that message is submitted.
 *
 * - ctrl+s with text: stash it and clear the editor (swaps with an existing stash).
 * - ctrl+s on an empty editor: restore the stash.
 * - submitting a prompt restores the stash into the emptied editor.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const WIDGET_KEY = "stash";
const PREVIEW_CHARS = 60;

const preview = (text: string) => {
  const line = text.trim().split("\n")[0];
  return line.length > PREVIEW_CHARS ? `${line.slice(0, PREVIEW_CHARS)}…` : line;
};

export default function (pi: ExtensionAPI) {
  let stash: string | undefined;

  // A widget rather than setStatus: powerbar replaces the footer and drops unregistered statuses.
  const showStash = (ctx: ExtensionContext) =>
    ctx.ui.setWidget(
      WIDGET_KEY,
      stash === undefined
        ? undefined
        : [ctx.ui.theme.fg("dim", `stashed (ctrl+s restores): ${preview(stash)}`)],
    );

  // Overrides the ctrl+s save actions only in the editor; the model/thinking/session pickers keep theirs.
  pi.registerShortcut("ctrl+s", {
    description: "Stash the prompt until the next submit",
    handler: (ctx) => {
      const text = ctx.ui.getEditorText();
      if (text.trim()) {
        ctx.ui.setEditorText(stash ?? "");
        stash = text;
      } else if (stash !== undefined) {
        ctx.ui.setEditorText(stash);
        stash = undefined;
      }
      showStash(ctx);
    },
  });

  pi.on("input", (event, ctx) => {
    // The editor is already cleared by the time input handlers run; anything in it is newly typed.
    if (event.source !== "interactive" || stash === undefined || ctx.ui.getEditorText().trim())
      return;
    ctx.ui.setEditorText(stash);
    stash = undefined;
    showStash(ctx);
  });
}
