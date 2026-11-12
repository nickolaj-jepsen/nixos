/**
 * The pi half of the answer form: when a turn ends on a question round or a
 * pick list, a widget offers a form for it. alt+a or /answer opens it in the
 * editor's place, and its review writes the reply into the editor, above any
 * draft, to send.
 *
 * The form is the core's (`../core/forms.ts`), the one Claude Code's mod runs.
 * The draft is this session's own: in memory, and on the session branch so a
 * reload or a resumed session has its round and answers back.
 *
 * The answers outlive closing the form; any input sent drops them.
 */
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { contentText } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type Held, offer, step as stepForm, type View, view, viewOf } from "../core/forms.ts";
import { AnswerForm, type FormAction, type FormResult } from "./form.ts";

const WIDGET_KEY = "answer";
const SHORTCUT = "alt+a";
const ENTRY = "answer-form";

/** What the branch keeps: the form as it stood, or null once the person spoke past it. */
type Saved = { held: Held | null };

const hasEditor = (ctx: ExtensionContext) => ctx.mode === "tui" && ctx.hasUI;

function lastAssistantText(messages: AgentMessage[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m?.role !== "assistant") continue;
    const text = contentText(m.content, "\n").trim();
    if (text) return text;
  }
  return "";
}

/** The reply above what the person had typed, never over it. */
const placeReply = (draft: string, text: string) => (draft.trim() ? `${text}\n\n${draft}` : text);

/** Everything the widget draws of a view, so a step that changes none of it costs no redraw. */
const signature = (view: View | null) => (view ? `${view.id}|${view.answered}` : "");

/** A record another version wrote, or a corrupt one, is skipped rather than believed. */
const isSaved = (data: unknown): data is Saved => {
  if (typeof data !== "object" || data === null || !("held" in data)) return false;
  const { held } = data as { held: unknown };
  if (held === null) return true;
  const { form, draft } = held as { form?: { items?: unknown }; draft?: { answers?: unknown } };
  return (
    Array.isArray(form?.items) &&
    Array.isArray(draft?.answers) &&
    form.items.length === draft.answers.length
  );
};

/** The form the branch last held, so a fork or a resumed session starts from its own. */
function restored(ctx: ExtensionContext): Held | null {
  const branch = ctx.sessionManager.getBranch();
  for (let i = branch.length - 1; i >= 0; i--) {
    const entry = branch[i];
    if (entry?.type !== "custom" || entry.customType !== ENTRY) continue;
    if (isSaved(entry.data)) return entry.data.held;
  }
  return null;
}

export default function (pi: ExtensionAPI) {
  let held: Held | null = null;
  /** What the widget last drew. */
  let shown = "";
  let lastText = "";
  let form: AnswerForm | undefined;

  const draw = (ctx: ExtensionContext) => {
    const view = viewOf(held);
    form?.refresh(view);
    const next = signature(view);
    if (next === shown) return;
    shown = next;
    if (!view) return ctx.ui.setWidget(WIDGET_KEY, undefined);
    const t = ctx.ui.theme;
    const { answered, title } = view;
    ctx.ui.setWidget(WIDGET_KEY, [
      t.fg("accent", title) +
        t.fg("dim", `${answered ? ` · ${answered} answered` : ""} · ${SHORTCUT} or /answer`),
    ]);
  };

  /** Holds `next`, on the branch too when it changed. */
  const hold = (ctx: ExtensionContext, next: Held | null) => {
    if (next !== held) pi.appendEntry<Saved>(ENTRY, { held: next });
    held = next;
    draw(ctx);
  };

  pi.on("session_start", (_event, ctx) => {
    if (!hasEditor(ctx)) return;
    held = restored(ctx);
    shown = "";
    draw(ctx);
  });

  pi.on("agent_end", (event) => {
    lastText = lastAssistantText(event.messages);
  });

  // A turn that asks nothing leaves the form: a background task's turn ends on that task's news.
  pi.on("agent_settled", (event, ctx) => {
    if (!hasEditor(ctx) || event.aborted) return;
    hold(ctx, offer(held, lastText));
  });

  // Anything sent answers the round, or moves past it.
  pi.on("input", (_event, ctx) => {
    if (held) hold(ctx, null);
  });

  const open = async (ctx: ExtensionContext) => {
    if (!hasEditor(ctx) || form) return;
    const answering = held;
    const opened = answering && view(answering.form, answering.draft);
    if (!answering || !opened) {
      ctx.ui.notify("Nothing to answer: the last turn asked no questions.", "info");
      return;
    }
    // Aimed at the form that was opened, so a round that arrived meanwhile is left as it is.
    const step = async (action: FormAction) => {
      if (held) hold(ctx, stepForm(held, action, opened.id));
      return viewOf(held);
    };
    // Every question's screen, so the form stands as tall as its tallest on all of them.
    const steps = answering.form.items.map((_, at) =>
      view(answering.form, { ...answering.draft, step: at }),
    );
    let result: FormResult;
    try {
      result = await ctx.ui.custom<FormResult>(
        (tui, theme, _keybindings, done) => {
          form = new AnswerForm(tui, theme, opened, step, done, steps);
          return form;
        },
        { overlay: false },
      );
    } finally {
      form = undefined;
    }
    // A turn that ended while the form was up has replaced what it answered.
    const now = viewOf(held);
    if (now?.id === opened.id && result.fill && now.reply)
      ctx.ui.setEditorText(placeReply(ctx.ui.getEditorText(), now.reply));
  };

  pi.registerShortcut(SHORTCUT, {
    description: "Answer the questions or pick list the last turn ended on",
    handler: (ctx) => open(ctx),
  });

  pi.registerCommand("answer", {
    description: "Answer the questions or pick list the last turn ended on, from a form",
    handler: async (_args, ctx) => open(ctx),
  });
}
