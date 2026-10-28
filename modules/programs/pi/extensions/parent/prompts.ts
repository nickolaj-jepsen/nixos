/**
 * What the prompt box keeps between sessions: the history up-arrow browses, so a
 * prompt typed in one session is reachable in the next, and the draft the editor
 * held, so a window closed mid-sentence gets its text back on --resume.
 *
 * Both live per repository rather than per directory, so a worktree browses and
 * restores alongside the checkout it came from.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { held, readPrompts, updatePrompts } from "./lib/prompt-store.ts";
import type { Services } from "./services.ts";

/** How long the editor must rest before its draft is written. */
const SETTLE_MS = 400;

/** Only the TUI has a prompt box; a print or RPC run has no draft to keep. */
const hasEditor = (ctx: ExtensionContext) => ctx.mode === "tui" && ctx.hasUI;

export default function (pi: ExtensionAPI, { editorHooks }: Services) {
  /** The session whose draft the editor holds; pi builds a new runtime per session as well. */
  let session: { id: string; cwd: string } | undefined;
  /** What the file holds for `session`, so a rest timer that changes nothing writes nothing. */
  let written: string | undefined;
  let pending: string | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;

  const write = (text: string) => {
    if (!session) return;
    const { id, cwd } = session;
    written = text;
    updatePrompts(cwd, (prompts) => {
      if (text.trim()) prompts.drafts[id] = held(text);
      else delete prompts.drafts[id];
    });
  };

  const flush = () => {
    if (timer) clearTimeout(timer);
    timer = undefined;
    const text = pending;
    pending = undefined;
    if (text !== undefined && text !== written) write(text);
  };

  // Every keystroke, paste and `setText`, including pi's own restore on resume.
  editorHooks.add({
    onEdit: (draft) => {
      pending = draft.getText();
      if (timer) clearTimeout(timer);
      timer = setTimeout(flush, SETTLE_MS);
      timer.unref?.();
    },
  });

  pi.on("session_start", (_event, ctx) => {
    if (!hasEditor(ctx)) return;
    const cwd = ctx.sessionManager.getCwd();
    session = { id: ctx.sessionManager.getSessionId(), cwd };
    const { history, drafts } = readPrompts(cwd);
    // Oldest first: the editor's ring takes the newest prompt to the top, where
    // pi then puts the session's own, replayed after this handler.
    for (const text of [...history].reverse()) editorHooks.current()?.addToHistory(text);
    written = drafts[session.id]?.text ?? "";
    if (written.trim() && !ctx.ui.getEditorText().trim()) ctx.ui.setEditorText(written);
  });

  // A submitted prompt joins the repository's history; the editor's own ring
  // already holds it, and this is what the session after this one starts from.
  pi.on("input", (event, ctx) => {
    const text = event.text.trim();
    if (event.source !== "interactive" || !text) return;
    updatePrompts(ctx.sessionManager.getCwd(), (prompts) => {
      if (prompts.history[0] !== text) prompts.history.unshift(text);
    });
  });

  pi.on("session_shutdown", flush);
}
