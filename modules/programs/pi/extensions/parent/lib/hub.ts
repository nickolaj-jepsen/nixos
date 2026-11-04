/**
 * This session's connection to agent-hub, the daemon that names and judges
 * every live agent session (pkgs/agent-hub; `agent_hub/protocol.py` defines every
 * message, and the build generates `protocol.gen.ts` from it). The session
 * attaches for its life: it reports its turns and dialogs with where its session
 * file and leaf are, which the hub reads for itself, runs the model calls the hub
 * asks for with pi's own side model, and gets back its row, which is what every
 * surface shows about it: the state, why, the label, the step in flight, the ask
 * and a drafted reply.
 *
 * Opened at session_start in the TUI and reopened when the daemon restarts or
 * comes up later; each (re)attach re-sends what the session already knows. A
 * hub on another protocol version refuses the attach, and the session says so
 * once and stays off it. A host without the hub leaves the row undefined.
 *
 * The same connection subscribes, so the session can read every row the hub has
 * (never as a `bar`, which is a surface that can open a reader), go to, resume or
 * dismiss another session's row, and put its notes up in the bar's reader; and it
 * writes an answer form through the hub's form ops rather than a process per step:
 * each one goes through `formstore` and is published, so the file stays the one
 * truth and the next push carries the view.
 */
import { connect, type Socket } from "node:net";
import { homedir } from "node:os";
import path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Dialogs } from "./dialogs.ts";
import {
  type HubDelivery,
  type HubFormView,
  type HubIdentity,
  type HubMessage,
  type HubNote,
  type HubOp,
  type HubRow,
  PROTOCOL_VERSION,
} from "./protocol.gen.ts";

/** One step of a session's answer form, as `forms.apply` takes it. */
export type FormAction = { do: string; entry?: number; step?: number; text?: string };

/** A model call the hub wants run; `signal` aborts when the hub cancels it. */
export type JudgeRequest = {
  system: string;
  prompt: string;
  maxTokens: number;
  source: string;
  signal: AbortSignal;
};

/** What an attach re-sends: the persisted identity and the person's own name, if any. */
export type AttachInfo = { record: HubIdentity; name?: string };

type Status = "busy" | "idle" | "waiting";

// A daemon that is down now may be up later; asking again is one failed connect.
const RETRY_MS = 5000;
// The first read of a long session's notes takes seconds; a person waits, not a turn.
const NOTES_TIMEOUT_MS = 15_000;
const SHOW_TIMEOUT_MS = 1000;
// A form op is a file write and a publish: a second without a reply means a daemon
// that doesn't know the op, which is the caller's cue to take the CLI instead.
const FORM_TIMEOUT_MS = 1000;

// As the daemon's `socket_path`: the runtime dir, or the state dir where there is none (macOS).
const socketPath = () => {
  const runtime = process.env.XDG_RUNTIME_DIR;
  if (runtime) return path.join(runtime, "agent-hub", "hub.sock");
  const state = process.env.XDG_STATE_HOME || path.join(homedir(), ".local", "state");
  return path.join(state, "agent-hub", "hub.sock");
};

export const createHub = (pi: ExtensionAPI, dialogs: Dialogs) => {
  /** Features that repaint this session's own row. */
  const listeners = new Set<() => void>();
  /** Features that draw the whole hub: the overlay, and anything else listing other sessions. */
  const rowsListeners = new Set<() => void>();
  let row: HubRow | undefined;
  let state: Extract<HubMessage, { type: "state" }> | undefined;
  let identity: HubIdentity | undefined;
  let ctx: ExtensionContext | undefined;
  let live = false;
  let socket: Socket | undefined;
  let attached = false;
  /** Set once a hub on another version turns the session away; it is not asked again. */
  let refused = false;
  /** False once the hub says it does not know the form ops: an older daemon, and the CLI does them. */
  let formOps = true;
  let status: Status = "idle";
  let since = Date.now();
  let attachInfo: () => AttachInfo = () => ({ record: {} });
  let judge: ((request: JudgeRequest) => Promise<string | undefined>) | undefined;
  let requests = 0;
  const replies = new Map<
    number,
    (reply: Extract<HubMessage, { type: "reply" }> | undefined) => void
  >();
  const judging = new Map<number, AbortController>();

  const notify = () => {
    for (const listener of listeners) listener();
  };

  const notifyRows = () => {
    for (const listener of rowsListeners) listener();
  };

  const write = (message: HubOp) => {
    if (!socket || !attached) return false;
    socket.write(`${JSON.stringify(message)}\n`);
    return true;
  };

  /** Sends what `build` makes of a new request number; undefined when no reply comes in time. */
  const ask = (build: (request: number) => HubOp, timeoutMs: number) => {
    if (!attached) return Promise.resolve(undefined);
    requests += 1;
    const request = requests;
    return new Promise<Extract<HubMessage, { type: "reply" }> | undefined>((resolve) => {
      const timer = setTimeout(() => {
        replies.delete(request);
        resolve(undefined);
      }, timeoutMs);
      replies.set(request, (reply) => {
        clearTimeout(timer);
        resolve(reply);
      });
      write(build(request));
    });
  };

  /** A form op, naming this session; undefined when the CLI should do it instead. */
  const formAsk = (build: (request: number, session: string) => HubOp) => {
    const session = ctx?.sessionManager.getSessionId();
    if (session === undefined || !formOps) return Promise.resolve(undefined);
    return ask((request) => build(request, session), FORM_TIMEOUT_MS);
  };

  const setStatus = (next: Status) => {
    if (next !== status) since = Date.now();
    status = next;
  };

  /** Ends what the connection had in flight: replies come back empty, model calls abort. */
  const settle = () => {
    for (const resolve of replies.values()) resolve(undefined);
    replies.clear();
    for (const controller of judging.values()) controller.abort();
    judging.clear();
  };

  const onJudge = async ({ request, ...call }: Extract<HubMessage, { type: "judge" }>) => {
    const controller = new AbortController();
    judging.set(request, controller);
    const text = judge
      ? await judge({ ...call, signal: controller.signal }).catch(() => undefined)
      : undefined;
    judging.delete(request);
    write(text === undefined ? { op: "judged", request } : { op: "judged", request, text });
  };

  const onMessage = (message: HubMessage) => {
    if (message.type === "row") {
      row = message.row ?? undefined;
      identity = message.identity;
      notify();
    } else if (message.type === "state") {
      state = message;
      // Only what draws other sessions cares: the session's own row did not move.
      notifyRows();
    } else if (message.type === "judge") {
      void onJudge(message);
    } else if (message.type === "cancel") {
      judging.get(message.request)?.abort();
    } else if (message.type === "reply") {
      replies.get(message.request)?.(message);
      replies.delete(message.request);
    } else if (message.type === "error") {
      // A write the hub refused, an op it doesn't know among them: fail it now, not at its
      // timeout, so the caller can take the CLI instead.
      if (message.request !== undefined) {
        replies.get(message.request)?.(undefined);
        replies.delete(message.request);
      }
      // An older daemon: every form op would fail the same way, so stop asking for them.
      if (/^unknown op 'form-/.test(message.error)) formOps = false;
    } else if (message.type === "notice" && live && ctx) {
      ctx.ui.notify(message.text, "warning");
    } else if (message.type === "refused") {
      refused = true;
      if (live && ctx) ctx.ui.notify(message.text, "warning");
    }
  };

  /** Where the hub reads the session: its file, absent with --no-session, and the current leaf. */
  const transcript = (c: ExtensionContext) => ({
    transcript: c.sessionManager.getSessionFile() ?? null,
    leaf: c.sessionManager.getLeafId(),
  });

  const open = () => {
    if (!live || !ctx || process.env.AGENT_HUB === "off") return;
    const current = connect(socketPath());
    socket = current;
    let buffered = "";

    // `error` and `close` both fire for one broken connection; the first one to
    // clear it wins, and the session's own end leaves no retry behind.
    const lost = () => {
      if (socket !== current) return;
      socket = undefined;
      attached = false;
      settle();
      current.destroy();
      // Rows of a hub that is gone are not worth reading; the next subscribe sends them again.
      if (row !== undefined || state !== undefined) {
        row = undefined;
        state = undefined;
        notify();
        notifyRows();
      }
      if (!live || refused) return;
      setTimeout(open, RETRY_MS).unref();
    };

    current.on("connect", () => {
      if (!ctx) return;
      const { record, name } = attachInfo();
      const waitingFor = dialogs.current();
      attached = true;
      formOps = true;
      write({
        op: "attach",
        version: PROTOCOL_VERSION,
        session: ctx.sessionManager.getSessionId(),
        pid: process.pid,
        cwd: ctx.cwd,
        status: waitingFor ? "waiting" : status,
        since,
        waitingFor: waitingFor ?? null,
        name: name ?? null,
        record,
        ...(process.env.AGENT_HUB_HIDDEN === "1" ? { hidden: true } : {}),
        tmux: process.env.TMUX_PANE ?? null,
        ...transcript(ctx),
      });
      // The whole hub's rows arrive as one `state` after this, and every publish updates it.
      // Not `bar`: that asks the hub to hand this connection readers, which this one can't open.
      write({ op: "subscribe" });
    });
    current.on("data", (chunk: Buffer) => {
      buffered += chunk.toString("utf8");
      let end = buffered.indexOf("\n");
      while (end >= 0) {
        const line = buffered.slice(0, end);
        buffered = buffered.slice(end + 1);
        end = buffered.indexOf("\n");
        if (line.trim() === "") continue;
        try {
          // The hub refuses a client on another version, so what it sends has these shapes.
          onMessage(JSON.parse(line) as HubMessage);
        } catch {
          // A line this client cannot read is not worth an error in the footer.
        }
      }
    });
    current.on("error", lost);
    current.on("close", lost);
  };

  /**
   * Puts the bar's reader up: on `session`'s notes, at `path` when one is named,
   * else this session's latest. False when no bar took them.
   */
  const showReader = (session?: string, path?: string) =>
    ask(
      (request) => ({
        op: "show",
        request,
        ...(session === undefined ? {} : { session }),
        ...(path === undefined ? {} : { path }),
      }),
      SHOW_TIMEOUT_MS,
    ).then((reply) => reply?.shown === true);

  dialogs.onChange(() => {
    const waitingFor = dialogs.current();
    setStatus(waitingFor ? "waiting" : "busy");
    write({ op: "dialog", text: waitingFor ?? null });
  });

  pi.on("session_start", (_event, c) => {
    // Headless runs never register with the hub, so there is nothing to ask about.
    if (c.mode !== "tui" || !c.hasUI) return;
    ctx = c;
    live = true;
    refused = false;
    status = "idle";
    since = Date.now();
    open();
  });

  pi.on("session_shutdown", () => {
    live = false;
    ctx = undefined;
    attached = false;
    settle();
    socket?.destroy();
    socket = undefined;
    row = undefined;
    state = undefined;
    identity = undefined;
  });

  return {
    /** The row as last pushed, or undefined while the hub has said nothing about the session. */
    read: () => row,
    /** Every row the hub reported when it last published, newest last; empty with no hub. */
    rows: () => state?.sessions ?? [],
    /** The sessions that ended, newest first, as far as the hub still lists them. */
    recent: () => state?.recent ?? [],
    /** What the hub last said the session is called. */
    identity: () => identity,
    /** Whether the session is attached right now. */
    connected: () => attached,
    /** Whether this hub takes the form ops; false for a daemon older than them. */
    formsOverSocket: () => formOps,
    /** Registers `listener` for every change of this session's row; returns the unsubscribe. */
    onChange(listener: () => void) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    /**
     * Registers `listener` for every change of the rows the hub pushed, this session's own
     * among them. A feature that only repaints its own row wants `onChange`.
     */
    onRows(listener: () => void) {
      rowsListeners.add(listener);
      return () => {
        rowsListeners.delete(listener);
      };
    },
    /** What each (re)attach re-sends. */
    attachWith(info: () => AttachInfo) {
      attachInfo = info;
    },
    /** Runs the hub's model calls; an undefined answer reports the call as failed. */
    judgeWith(run: (request: JudgeRequest) => Promise<string | undefined>) {
      judge = run;
    },
    /**
     * A turn starts on `prompt`, which is not on the branch yet; `fromPerson` is
     * false for a peer's message or a steer, and `peer` true for a peer's alone.
     * Resolves with the hub's note on the other sessions in this tree, or
     * undefined after `timeoutMs`.
     */
    turnStart(
      prompt: string,
      fromPerson: boolean,
      peer: boolean,
      worktreeTool: boolean,
      timeoutMs: number,
    ) {
      setStatus("busy");
      if (!attached || !ctx) return Promise.resolve(undefined);
      const where = transcript(ctx);
      return ask(
        (request) => ({
          op: "turn-start",
          request,
          prompt,
          fromPerson,
          peer,
          worktreeTool,
          ...where,
        }),
        timeoutMs,
      ).then((reply) => reply?.peers);
    },
    /** Puts this session's notes up in the bar's reader; false when there is no bar to show them. */
    showNotes: () => showReader(),
    /** The same for another session's notes, at `path` when one is named. */
    show: (session?: string, path?: string) => showReader(session, path),
    /** What this session wrote, read, and the rest of its project's; undefined with no hub. */
    notes: (): Promise<HubNote[] | undefined> =>
      ask((request) => ({ op: "notes", request }), NOTES_TIMEOUT_MS).then((reply) => reply?.notes),
    /**
     * Goes to another session: its window on this host, else its tmux pane or
     * Remote Control page over there. False when there is no hub to go through.
     */
    focus: (session: string) => write({ op: "focus", session }),
    /** Brings an ended session back in a new terminal, over ssh when it ended elsewhere. */
    resume: (session: string) => write({ op: "resume", session }),
    /** Puts away a session's finished turn, or that turn alone when it is named. */
    dismiss: (session: string, turn?: number) =>
      write({ op: "dismiss", session, ...(turn === undefined ? {} : { turn }) }),
    /** The turn settled; `pending` background jobs still run for it, `error` if the run failed. */
    turnEnd(pending: number, error: boolean) {
      setStatus("idle");
      if (ctx) write({ op: "turn-end", pending, error, ...transcript(ctx) });
    },
    /**
     * Opens the form the turn ending on `text` asks for: the view, null when it asks
     * nothing, or undefined when no hub answered and the caller should use the CLI.
     */
    formOffer: (text: string) =>
      formAsk((request, session) => ({ op: "form-offer", request, session, text })).then((reply) =>
        reply ? { view: reply.view ?? null } : undefined,
      ),
    /** One step of `form`; the same "no hub answered" as `formOffer` when undefined. */
    formStep: (form: string, action: FormAction) =>
      formAsk((request, session) => ({ op: "form-step", request, session, form, action })).then(
        (reply) => (reply ? { view: reply.view ?? null } : undefined),
      ),
    /** The form as it stands, and a reply left for this TUI, handed over at most once. */
    formSync: () =>
      formAsk((request, session) => ({ op: "form-sync", request, session })).then((reply) =>
        reply ? { view: reply.view ?? null, delivery: reply.delivery ?? null } : undefined,
      ),
    /** Forgets the session's form, as the person speaking does; false when no hub took it. */
    formDrop: () =>
      formAsk((request, session) => ({ op: "form-drop", request, session })).then(
        (reply) => reply !== undefined,
      ),
    named(name: string | undefined) {
      write({ op: "named", name: name ?? null });
    },
    /** Asks for a reading now; false when the hub is not there to ask. */
    relabel: () => write({ op: "relabel" }),
  };
};

export type Hub = ReturnType<typeof createHub>;
