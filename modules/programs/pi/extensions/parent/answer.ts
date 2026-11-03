/**
 * The pi half of the answer form: when a turn ends on a question round or a
 * pick list, a widget offers a form for it. alt+a or /answer opens it in the
 * editor's place, and its review writes the reply into the editor, above any
 * draft, to send.
 *
 * The form itself is `agent-hub answer`'s, which works with the hub down, so
 * the draft is shared with Claude Code's mod and the hub's panel. With the hub
 * attached the draft is stepped over this session's socket and the hub pushes
 * the resulting view, so nothing is spawned per keystroke; a session with no hub
 * falls back to `agent-hub answer` and to following the form's file.
 *
 * The answers outlive closing the form; any input sent drops them.
 */
import { execFile } from "node:child_process";
import { stat } from "node:fs/promises";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { contentText } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { AnswerForm, type FormAction, type FormResult } from "./answer/form.ts";
import type { FormAction as HubFormAction, Hub } from "./lib/hub.ts";
import type { HubDelivery, HubFormView } from "./lib/protocol.gen.ts";
import type { Services } from "./services.ts";

const WIDGET_KEY = "answer";
const SHORTCUT = "alt+a";
// How often the form's file is read while the hub is not there to push it.
const POLL_MS = 1000;
// While attached the pushed row drives the widget, so the socket is only asked this
// often for a reply another surface left for this prompt.
const SAFETY_POLL_MS = 10_000;

type Delivery = { text: string; submit: boolean };
type Synced = { view: HubFormView | null; delivery: HubDelivery | null };

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

/** Everything the widget draws of a view, so a push that says the same costs no redraw. */
const signature = (view: HubFormView | null) =>
  view ? `${view.id}|${view.step}|${view.answered}|${view.pending}|${view.reply}` : "";

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

export default function (pi: ExtensionAPI, services: Services) {
  const hub: Hub = services.hub;
  let current: HubFormView | undefined;
  /** What the widget last drew, so a push that says the same costs no redraw. */
  let shown = "";
  let lastText = "";
  let form: AnswerForm | undefined;
  let latest: ExtensionContext | undefined;
  let ticking: ReturnType<typeof setInterval> | undefined;
  let tick = 0;
  let watched = { session: "", path: "", mtime: 0 };
  let isPolling = false;
  /** A reply taken while the form holds the editor, which can't show it; taken up when it closes. */
  let waiting: Delivery | undefined;

  const sessionOf = (ctx: ExtensionContext) => ctx.sessionManager.getSessionId();

  const viewFrom = async (ctx: ExtensionContext, args: string[], stdin?: string) =>
    JSON.parse(await run(sessionOf(ctx), args, stdin)) as HubFormView | null;

  const show = (ctx: ExtensionContext, view: HubFormView | null, force = false) => {
    const next = signature(view);
    if (next === shown && !force) return;
    shown = next;
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
    if (delivery.submit) return pi.sendUserMessage(delivery.text, { deliverAs: "followUp" });
    if (form) {
      waiting = delivery;
      return;
    }
    ctx.ui.setEditorText(placeReply(ctx.ui.getEditorText(), delivery.text));
  };

  // One verb, over the socket when the hub is attached and through the CLI when it is
  // not, or did not answer: a hub older than these ops answers an unknown one with an
  // error and no reply, which leaves the form working the way it did before them.

  const offer = async (ctx: ExtensionContext) => {
    const reply = await hub.formOffer(lastText);
    return reply ? reply.view : viewFrom(ctx, ["offer"], lastText);
  };

  const stepForm = async (ctx: ExtensionContext, id: string, action: FormAction) => {
    const reply = await hub.formStep(id, action as HubFormAction);
    return reply ? reply.view : viewFrom(ctx, ["step", "--form", id, JSON.stringify(action)]);
  };

  const syncForm = async (ctx: ExtensionContext): Promise<Synced> => {
    const reply = await hub.formSync();
    if (reply) return reply;
    const synced = (await viewFrom(ctx, ["sync"])) as Synced | null;
    if (!synced) throw new Error("no sync");
    return synced;
  };

  const dropForm = async (ctx: ExtensionContext) => {
    if (await hub.formDrop()) return;
    await run(sessionOf(ctx), ["drop"]);
  };

  /** The hub said a reply waits for this prompt: the file has it, and only once. */
  const takeDelivery = async (ctx: ExtensionContext) => {
    const { view, delivery } = await syncForm(ctx);
    if (!delivery) return;
    take(ctx, delivery);
    // Forced: the editor changed, and a widget that says the same thing draws nothing.
    show(ctx, view, true);
  };

  /** With no hub: the file another surface writes is the only news there is. */
  const pollFile = async (ctx: ExtensionContext) => {
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
    await takeDelivery(ctx);
  };

  const poll = async () => {
    const ctx = latest;
    if (!ctx || isPolling) return;
    isPolling = true;
    try {
      // Attached, the view arrives pushed; this only catches a delivery whose push was missed.
      if (!hub.connected()) await pollFile(ctx);
      else if (++tick % (SAFETY_POLL_MS / POLL_MS) === 0) await takeDelivery(ctx);
    } catch {
      // No agent-hub here, or it failed: the session goes on without a form.
    } finally {
      isPolling = false;
    }
  };

  hub.onChange(() => {
    const ctx = latest;
    // Losing the hub clears its row; the form is still the file's, and the poll has it.
    if (!ctx || !hub.connected()) return;
    const view = hub.read()?.answer ?? null;
    show(ctx, view);
    if (view?.pending) void takeDelivery(ctx).catch(() => undefined);
  });

  pi.on("session_start", (_event, ctx) => {
    if (!hasEditor(ctx)) return;
    latest = ctx;
    tick = 0;
    clearInterval(ticking);
    ticking = setInterval(() => void poll(), POLL_MS);
    ticking.unref();
  });

  pi.on("session_shutdown", () => {
    clearInterval(ticking);
    latest = undefined;
    waiting = undefined;
  });

  pi.on("agent_end", (event) => {
    lastText = lastAssistantText(event.messages);
  });

  // A turn that asks nothing leaves the form: a background task's turn ends on that task's news.
  pi.on("agent_settled", async (event, ctx) => {
    if (!hasEditor(ctx) || event.aborted) return;
    await offer(ctx).then(
      (view) => show(ctx, view),
      () => undefined,
    );
  });

  // Anything sent answers the round, or moves past it.
  pi.on("input", (_event, ctx) => {
    if (!current) return;
    show(ctx, null);
    void dropForm(ctx).catch(() => undefined);
  });

  const open = async (ctx: ExtensionContext) => {
    if (!hasEditor(ctx) || form) return;
    if (!current) {
      ctx.ui.notify("Nothing to answer: the last turn asked no questions.", "info");
      return;
    }
    const opened = current;
    const step = async (action: FormAction) => {
      const view = await stepForm(ctx, opened.id, action).catch(() => undefined);
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
    // Taking the form's own reply answers a delivery that waited for the form to close.
    const taken = waiting;
    waiting = undefined;
    // A turn that ended while the form was up has replaced what it answered.
    if (current?.id === opened.id && result.fill && current.reply) {
      ctx.ui.setEditorText(placeReply(ctx.ui.getEditorText(), current.reply));
    } else if (taken) {
      take(ctx, taken);
      // The editor holds a reply the TUI has to be told to draw.
      show(ctx, current ?? null, true);
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
