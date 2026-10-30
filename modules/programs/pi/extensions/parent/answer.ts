/**
 * The pi half of the answer form (Claude Code's mods/answer, whose core this
 * shares): when a turn ends on a question round or a pick list, a widget
 * offers a form for it. alt+a or /answer opens it in the editor's place, and
 * its review writes the reply into the editor, above any draft, to send.
 *
 * The answers outlive closing the form; any input sent drops them, as does the
 * next turn's ending.
 */
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { contentText } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { AnswerForm, type FormResult } from "./answer/form.ts";
import {
  type Draft,
  type Form,
  newDraft,
  parse,
  placeReply,
  reply,
} from "./lib/answer/hooks/core.ts";

const WIDGET_KEY = "answer";
const SHORTCUT = "alt+a";

const hasEditor = (ctx: ExtensionContext) => ctx.mode === "tui" && ctx.hasUI;

function lastAssistantText(messages: AgentMessage[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m.role !== "assistant") continue;
    const text = contentText(m.content, "\n").trim();
    if (text) return text;
  }
  return "";
}

const title = (form: Form) => {
  const n = form.items.length;
  return form.kind === "round"
    ? `Answer ${n} question${n === 1 ? "" : "s"}`
    : `Pick from ${n} item${n === 1 ? "" : "s"}`;
};

export default function (pi: ExtensionAPI) {
  let current: { form: Form; draft: Draft } | undefined;
  let lastText = "";
  let isOpen = false;

  const show = (ctx: ExtensionContext) => {
    if (!current) return ctx.ui.setWidget(WIDGET_KEY, undefined);
    const done = current.draft.answers.filter(Boolean).length;
    const t = ctx.ui.theme;
    ctx.ui.setWidget(WIDGET_KEY, [
      t.fg("accent", title(current.form)) +
        t.fg("dim", `${done ? ` · ${done} answered` : ""} · ${SHORTCUT} or /answer`),
    ]);
  };

  pi.on("agent_end", (event) => {
    lastText = lastAssistantText(event.messages);
  });

  pi.on("agent_settled", (event, ctx) => {
    if (!hasEditor(ctx)) return;
    const form = event.aborted ? null : parse(lastText);
    current = form ? { form, draft: newDraft(form) } : undefined;
    show(ctx);
  });

  // Anything sent answers the round, or moves past it.
  pi.on("input", (_event, ctx) => {
    if (!current) return;
    current = undefined;
    show(ctx);
  });

  const open = async (ctx: ExtensionContext) => {
    if (!hasEditor(ctx) || isOpen) return;
    if (!current) {
      ctx.ui.notify("Nothing to answer: the last turn asked no questions.", "info");
      return;
    }
    const { form, draft } = current;
    isOpen = true;
    let result: FormResult;
    try {
      result = await ctx.ui.custom<FormResult>(
        (tui, theme, _keybindings, done) => new AnswerForm(tui, theme, form, draft, done),
        { overlay: false },
      );
    } finally {
      isOpen = false;
    }
    // A turn that ended while the form was up has replaced what it answered.
    if (current?.form !== form) return;
    current = { form, draft: result.draft };
    show(ctx);
    const text = result.fill ? reply(form, result.draft) : "";
    if (text) ctx.ui.setEditorText(placeReply(ctx.ui.getEditorText(), text));
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
