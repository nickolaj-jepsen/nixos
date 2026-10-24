/**
 * Claude Code's ctrl+s prompt stash: park the draft in the editor, send
 * something else, and get the draft back once that message is submitted.
 *
 * - ctrl+s with text: stash it and clear the editor (swaps with an existing stash).
 * - ctrl+s on an empty editor: restore the stash.
 * - submitting a prompt restores the stash into the emptied editor.
 *
 * The stash outlives /new, /clear, /resume, /fork and /reload, which replace
 * this extension instance and clear its widget.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const WIDGET_KEY = "stash";
const PREVIEW_CHARS = 60;

const preview = (text: string) => {
  const line = text.trim().split("\n")[0];
  return line.length > PREVIEW_CHARS ? `${line.slice(0, PREVIEW_CHARS)}…` : line;
};

// On globalThis because each session replacement loads a fresh copy of this module.
const KEY = Symbol.for("fireproof.pi.stash");
const store = globalThis as { [KEY]?: string };

export default function (pi: ExtensionAPI) {
  // A widget rather than setStatus so the preview keeps its own line.
  const showStash = (ctx: ExtensionContext) => {
    const stash = store[KEY];
    ctx.ui.setWidget(
      WIDGET_KEY,
      stash === undefined
        ? undefined
        : [ctx.ui.theme.fg("dim", `stashed (ctrl+s restores): ${preview(stash)}`)],
    );
  };

  // A print, JSON or RPC run has no editor; its prompt must not consume the stash.
  const hasEditor = (ctx: ExtensionContext) => ctx.mode === "tui" && ctx.hasUI;

  pi.on("session_start", (_event, ctx) => {
    if (hasEditor(ctx)) showStash(ctx);
  });

  // Editor-only; the pickers' ctrl+s save actions are moved to alt+s in ../../default.nix.
  pi.registerShortcut("ctrl+s", {
    description: "Stash the prompt until the next submit",
    handler: (ctx) => {
      const text = ctx.ui.getEditorText();
      const stash = store[KEY];
      if (text.trim()) {
        ctx.ui.setEditorText(stash ?? "");
        store[KEY] = text;
      } else if (stash !== undefined) {
        ctx.ui.setEditorText(stash);
        store[KEY] = undefined;
      }
      showStash(ctx);
    },
  });

  pi.on("input", (event, ctx) => {
    // The editor is already cleared by the time input handlers run; anything in it is newly typed.
    const stash = store[KEY];
    if (
      !hasEditor(ctx) ||
      event.source !== "interactive" ||
      stash === undefined ||
      ctx.ui.getEditorText().trim()
    )
      return;
    ctx.ui.setEditorText(stash);
    store[KEY] = undefined;
    showStash(ctx);
  });
}
