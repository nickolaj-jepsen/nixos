/**
 * The pi half of the answer form: when a turn ends on a question round or a
 * pick list, a widget offers a form for it. alt+a or /answer opens it in the
 * editor's place, and its review writes the reply into the editor, above any
 * draft, to send.
 *
 * The form itself is `agent-hub answer`'s, which works with the hub down, so
 * the draft is shared with Claude Code's mod and the hub's panel: this follows
 * the form's file, shows what they do, and takes the replies they leave.
 *
 * The answers outlive closing the form; any input sent drops them.
 */
import { execFile } from "node:child_process";
import { stat } from "node:fs/promises";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { contentText } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { AnswerForm, type FormAction, type FormResult } from "./answer/form.ts";
import type { HubFormView } from "./lib/protocol.gen.ts";

const WIDGET_KEY = "answer";
const SHORTCUT = "alt+a";
// How soon something another surface did to the form shows here.
const POLL_MS = 1000;

type Delivery = { text: string; submit: boolean };

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

/** The reply above what the person had typed, never over it. */
const placeReply = (draft: string, text: string) => (draft.trim() ? `${text}\n\n${draft}` : text);

function run(session: string, args: string[], stdin?: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = execFile(
      "agent-hub",
      ["answer", ...args, "--session", session],
      { encoding: "utf8", timeout: 5000 },
      (error, stdout) => (error ? reject(error) : resolve(stdout)),
    );
    child.stdin?.end(stdin ?? "");
  });
}

export default function (pi: ExtensionAPI) {
  let current: HubFormView | undefined;
  let lastText = "";
  let form: AnswerForm | undefined;
  let latest: ExtensionContext | undefined;
  let ticking: ReturnType<typeof setInterval> | undefined;
  let watched = { session: "", path: "", mtime: 0 };
  let isPolling = false;

  const sessionOf = (ctx: ExtensionContext) => ctx.sessionManager.getSessionId();

  const viewFrom = async (ctx: ExtensionContext, args: string[], stdin?: string) =>
    JSON.parse(await run(sessionOf(ctx), args, stdin)) as HubFormView | null;

  const show = (ctx: ExtensionContext, view: HubFormView | null) => {
    current = view ?? undefined;
    form?.refresh(view);
    if (!current) return ctx.ui.setWidget(WIDGET_KEY, undefined);
    const t = ctx.ui.theme;
    const { answered, title } = current;
    ctx.ui.setWidget(WIDGET_KEY, [
      t.fg("accent", title) +
        t.fg("dim", `${answered ? ` · ${answered} answered` : ""} · ${SHORTCUT} or /answer`),
    ]);
  };

  /** A reply left at another surface: into the editor, or sent as you sending it. */
  const take = (ctx: ExtensionContext, delivery: Delivery) => {
    if (delivery.submit) pi.sendUserMessage(delivery.text, { deliverAs: "followUp" });
    else ctx.ui.setEditorText(placeReply(ctx.ui.getEditorText(), delivery.text));
  };

  const poll = async () => {
    const ctx = latest;
    if (!ctx || isPolling) return;
    isPolling = true;
    try {
      const session = sessionOf(ctx);
      if (session !== watched.session) {
        watched = { session, path: (await run(session, ["path"])).trim(), mtime: 0 };
      }
      const mtime = await stat(watched.path).then(
        (s) => s.mtimeMs,
        () => 0,
      );
      if (mtime === watched.mtime) return;
      watched.mtime = mtime;
      const { view, delivery } = JSON.parse(await run(session, ["sync"])) as {
        view: HubFormView | null;
        delivery: Delivery | null;
      };
      show(ctx, view);
      if (delivery) take(ctx, delivery);
    } catch {
      // No agent-hub here, or it failed: the session goes on without a form.
    } finally {
      isPolling = false;
    }
  };

  pi.on("session_start", (_event, ctx) => {
    if (!hasEditor(ctx)) return;
    latest = ctx;
    clearInterval(ticking);
    ticking = setInterval(() => void poll(), POLL_MS);
    ticking.unref();
  });

  pi.on("session_shutdown", () => {
    clearInterval(ticking);
    latest = undefined;
  });

  pi.on("agent_end", (event) => {
    lastText = lastAssistantText(event.messages);
  });

  // A turn that asks nothing leaves the form: a background task's turn ends on that task's news.
  pi.on("agent_settled", async (event, ctx) => {
    if (!hasEditor(ctx) || event.aborted) return;
    await viewFrom(ctx, ["offer"], lastText).then(
      (view) => show(ctx, view),
      () => undefined,
    );
  });

  // Anything sent answers the round, or moves past it.
  pi.on("input", (_event, ctx) => {
    if (!current) return;
    show(ctx, null);
    void run(sessionOf(ctx), ["drop"]).catch(() => undefined);
  });

  const open = async (ctx: ExtensionContext) => {
    if (!hasEditor(ctx) || form) return;
    if (!current) {
      ctx.ui.notify("Nothing to answer: the last turn asked no questions.", "info");
      return;
    }
    const opened = current;
    const step = async (action: FormAction) => {
      const view = await viewFrom(ctx, ["step", "--form", opened.id, JSON.stringify(action)]).catch(
        () => undefined,
      );
      if (view !== undefined) show(ctx, view);
      return view ?? null;
    };
    let result: FormResult;
    try {
      result = await ctx.ui.custom<FormResult>(
        (tui, theme, _keybindings, done) => {
          form = new AnswerForm(tui, theme, opened, step, done);
          return form;
        },
        { overlay: false },
      );
    } finally {
      form = undefined;
    }
    // A turn that ended while the form was up has replaced what it answered.
    if (current?.id !== opened.id) return;
    if (result.fill && current.reply) {
      ctx.ui.setEditorText(placeReply(ctx.ui.getEditorText(), current.reply));
    }
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
