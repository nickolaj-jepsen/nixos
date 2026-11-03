/**
 * The frame around pi's editor: the top border names the session, the footer
 * shows the model, spend and git. Modules live in `chrome/`.
 */
import type { ExtensionAPI, ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { createActions } from "./chrome/actions.ts";
import { openReview } from "./chrome/apps.ts";
import { createBorder } from "./chrome/border.ts";
import { PromptEditor, type Painters } from "./chrome/editor.ts";
import { createFooter } from "./chrome/footer.ts";
import { createGit } from "./chrome/git.ts";
import { measurementLevels } from "./chrome/measurements.ts";
import { NOTE_ENTRY, type NoteEntry, recordedNotes, writtenNote } from "./chrome/notes.ts";
import { createState } from "./chrome/state.ts";
import { createTitle } from "./chrome/title.ts";
import type { Services } from "./services.ts";

// pi's root types omit EditorFactory, so it comes from the one API that takes it.
type EditorFactory = NonNullable<Parameters<ExtensionUIContext["setEditorComponent"]>[0]>;

export default function (pi: ExtensionAPI, { identity, userWait, editorHooks, hub }: Services) {
  const state = createState();
  const git = createGit(state);
  // Registered before the modules, so their handlers already see the session. pi
  // builds a fresh runtime, and so a fresh instance of this, for every session.
  pi.on("session_start", (_event, ctx) => {
    state.ctx = ctx;
    state.live = ctx.mode === "tui" && ctx.hasUI;
  });
  const actions = createActions(pi, state, git, hub);
  const openArgs = [
    { value: "plan", label: "plan", description: "this session's notes" },
    { value: "diff", label: "diff", description: "review the changes in tuicr" },
  ];
  // The footer's two menus, reachable without a mouse: the same popovers, so the
  // keys and a click cannot drift apart.
  pi.registerCommand("open", {
    description:
      "Open this folder in an editor, file manager or terminal, or copy its path; /open plan opens this session's notes, /open diff reviews the changes in tuicr",
    getArgumentCompletions: (prefix) => {
      const hits = openArgs.filter((a) => a.value.startsWith(prefix));
      return hits.length ? hits : null;
    },
    handler: async (args, ctx) => {
      if (args.trim() === "diff") {
        try {
          await openReview(ctx.cwd);
        } catch (error) {
          ctx.ui.notify(
            `chrome: ${error instanceof Error ? error.message : String(error)}`,
            "error",
          );
          return;
        }
        // The review happens outside pi, so the model learns where to read it back.
        pi.sendMessage(
          {
            customType: "tuicr-review",
            content: `I opened tuicr in a separate window to review the changes in ${ctx.cwd}. When I say the review is done, find that session with \`tuicr review list --repo ${ctx.cwd}\`, read my comments with \`tuicr review comments\` (the tuicr skill) and address them.`,
            display: false,
          },
          { deliverAs: "nextTurn" },
        );
        return;
      }
      await (args.trim() === "plan" ? actions.notes(ctx) : actions.folder(ctx));
    },
  });
  // Recorded as each write lands, for the hub to read: a codemode-nested write over 8 KiB keeps no path in the transcript.
  pi.on("tool_result", (event, ctx) => {
    const path = writtenNote(event, ctx.cwd);
    if (!path || recordedNotes(ctx.sessionManager.getBranch()).has(path)) return;
    try {
      pi.appendEntry<NoteEntry>(NOTE_ENTRY, { path });
    } catch {
      // No session to write to (shutting down); the note goes unrecorded.
    }
  });
  pi.registerCommand("git", {
    description: "Open this branch, repository or pull request in the browser",
    handler: async (_args, ctx) => {
      await actions.git(ctx);
    },
  });
  identity.onChange(() => state.tui?.requestRender());
  createTitle(pi, state, identity, userWait);
  const border = createBorder(state, identity);
  const footer = createFooter(pi, state, actions, git, hub);
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
