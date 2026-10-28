/**
 * Claude Code's ctrl+s prompt stash: park the draft in the editor, send
 * something else, and get the draft back once that message is submitted.
 *
 * - ctrl+s with text: stash it and clear the editor (swaps with an existing stash).
 * - ctrl+s on an empty editor: restore the stash.
 * - submitting a prompt restores the stash into the emptied editor.
 *
 * The stash is saved in the repository's prompt file (lib/prompt-store.ts), so
 * it outlives /new, /clear, /resume, /fork, /reload and the process itself.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { held, type Held, readPrompts, updatePrompts } from "./lib/prompt-store.ts";

const WIDGET_KEY = "stash";
const PREVIEW_CHARS = 60;

const preview = (text: string) => {
  const line = text.trim().split("\n")[0];
  return line.length > PREVIEW_CHARS ? `${line.slice(0, PREVIEW_CHARS)}…` : line;
};

// A print, JSON or RPC run has no editor; its prompt must not consume the stash.
const hasEditor = (ctx: ExtensionContext) => ctx.mode === "tui" && ctx.hasUI;

export default function (pi: ExtensionAPI) {
  let stash: Held | undefined;
  let cwd: string | undefined;

  // A widget rather than setStatus so the preview keeps its own line.
  const show = (ctx: ExtensionContext) => {
    ctx.ui.setWidget(
      WIDGET_KEY,
      stash === undefined
        ? undefined
        : [ctx.ui.theme.fg("dim", `stashed (ctrl+s restores): ${preview(stash.text)}`)],
    );
  };

  const park = (text: string | undefined) => {
    if (!cwd) return;
    stash = text === undefined ? undefined : held(text);
    const parked = stash;
    updatePrompts(cwd, (prompts) => {
      if (parked) prompts.stash = parked;
      else delete prompts.stash;
    });
  };

  pi.on("session_start", (_event, ctx) => {
    if (!hasEditor(ctx)) return;
    cwd = ctx.sessionManager.getCwd();
    stash = readPrompts(cwd).stash;
    show(ctx);
  });

  // Editor-only; the pickers' ctrl+s save actions are moved to alt+s in ../../default.nix.
  pi.registerShortcut("ctrl+s", {
    description: "Stash the prompt until the next submit",
    handler: (ctx) => {
      const text = ctx.ui.getEditorText();
      if (text.trim()) {
        ctx.ui.setEditorText(stash?.text ?? "");
        park(text);
      } else if (stash) {
        ctx.ui.setEditorText(stash.text);
        park(undefined);
      }
      show(ctx);
    },
  });

  pi.on("input", (event, ctx) => {
    // The editor is already cleared by the time input handlers run; anything in it is newly typed.
    if (!hasEditor(ctx) || event.source !== "interactive" || !stash) return;
    if (ctx.ui.getEditorText().trim()) return;
    ctx.ui.setEditorText(stash.text);
    park(undefined);
    show(ctx);
  });
}
