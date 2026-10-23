/**
 * Which pi am I looking at: the terminal title, the editor's top border, and
 * `/header`.
 *
 * The title is the only surface visible from the niri overview, so it stays
 * terse — task label, directory, age, and a state word only when the session
 * wants you — with the directory last so elision drops the part the workspace
 * name already told you. The border row is
 * the persistent one inside pi: it carries the label and the path, and a click
 * on it relabels (`/header` still shows the age and session id). The label is deterministic
 * until you ask for a model one (alt+r or a click), plus a refresh at each
 * compaction boundary, which bounds the cost of a feature that only has to help
 * you pick a window.
 *
 * The border belongs to the editor; the wrapper in `editor.ts` calls `drawTop`
 * for the border row. The label never becomes the session name if you already
 * ran `/name`; the first model label becomes it once so `/resume` shows
 * something useful.
 */
import { homedir } from "node:os";
import { basename, relative, sep } from "node:path";
import {
  copyToClipboard,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import type { Region } from "./layout.ts";
import type { ChromeState } from "./state.ts";

type Phase = "working" | "idle" | "waiting" | "failed";
type Source = "name" | "prompt" | "cwd" | "model" | "manual";

type Label = {
  text: string;
  source: Source;
  at: number;
  calls: number;
  costUsd: number;
  /** True once this extension named the session, so it never renames it again. */
  namedSession: boolean;
};

const CUSTOM_TYPE = "identity_label";
const SHORTCUT = "alt+r";
const DEFAULT_MODEL = "opencode-go/deepseek-v4.1-flash";
const TICK_MS = 60_000;
// Pi animates its own spinner in this border while working; ours keeps the
// session feeling alive in the same spot, so the same cadence is fine.
const SPIN_MS = 120;
const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
// Worst case for a whole session; a relabel is a few hundred tokens, so this is
// less a budget than a guard against a click loop.
const CALL_CAP = 20;
const MAX_LABEL_CHARS = 40;
// Below this the label stops being the point of the row, so shed the detail first.
const MIN_LABEL_ROOM = 14;
// Roughly 1.5k tokens: prompts say what you want, touched files say what the
// agent is actually on, and neither grows with tool output.
const PROMPT_CHARS = 300;
const RECENT_PROMPTS = 5;
const TOUCHED_FILES = 6;
const TRIVIAL =
  /^(yes|yeah|yep|ok|okay|sure|agreed?|agree|continue|go on|go ahead|proceed|do it|sounds good|perfect|thanks|lgtm|carry on|next)\b/i;
// The deterministic label comes from a whole sentence, so drop the asking part.
const REQUEST_PREFIX = /^(?:(?:can|could|would|will) you (?:please )?|(?:please|help me|to) )/i;

const stripRequest = (text: string) => {
  let stripped = text.trim();
  for (let i = 0; i < 3; i++) {
    const next = stripped.replace(REQUEST_PREFIX, "");
    if (next === stripped) break;
    stripped = next;
  }
  return stripped;
};

const SYSTEM = `You name a coding session so its owner can pick the right terminal window from a list.
Reply with 2-6 lowercase words. No punctuation, no quotes, no "session", no trailing period.
Use the user's own words and concrete nouns from the file names. Name the work, not the fact that you agreed to something.`;

// Sub-agent widgets already own `●`, `○`, `⟳` and `▸`, so states that need you
// are words and "working" is either pi's spinner or a frozen frame of one.
const WORK_GLYPH = "⠿";
const stateWord = (phase: Phase) => (phase === "waiting" || phase === "failed" ? phase : "");

const userText = (content: string | Array<{ type: string; text?: string }>) =>
  typeof content === "string"
    ? content
    : content
        .flatMap((block) => (block.type === "text" && block.text ? [block.text] : []))
        .join("\n");

/** Short agreement replies are the bulk of a long session and say nothing new. */
const isSubstantive = (text: string) => {
  const trimmed = text.trim();
  const words = trimmed.split(/\s+/).length;
  return words >= 5 && !(words <= 8 && TRIVIAL.test(trimmed));
};

const oneLine = (text: string) => text.replace(/\s+/g, " ").trim();

const cleanLabel = (raw: string) => {
  const first = oneLine(raw).replace(/^(label|session|task)\s*:\s*/i, "");
  const unquoted = first.replace(/^["'`]+|["'`.,;:]+$/g, "");
  if (unquoted.length <= MAX_LABEL_CHARS) return unquoted;
  const cut = unquoted.slice(0, MAX_LABEL_CHARS);
  const lastSpace = cut.lastIndexOf(" ");
  return `${(lastSpace > 20 ? cut.slice(0, lastSpace) : cut).trim()}…`;
};

const formatCost = (usd: number) => (usd === 0 ? "$0" : `$${usd.toFixed(4)}`);

const formatAge = (ms: number) => {
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 48 ? `${hours}h` : `${Math.floor(hours / 24)}d`;
};

const shortPath = (cwd: string) => {
  const home = homedir();
  if (cwd === home) return "~";
  if (cwd.startsWith(home + sep)) {
    const parts = relative(home, cwd).split(sep).filter(Boolean);
    return parts.length <= 2 ? `~/${parts.join("/")}` : `~/…/${parts[parts.length - 1]}`;
  }
  const parts = cwd.split(sep).filter(Boolean);
  return parts.length <= 2 ? `/${parts.join("/")}` : `/${parts[0]}/…/${parts[parts.length - 1]}`;
};

export const createIdentity = (pi: ExtensionAPI, state: ChromeState) => {
  let timer: ReturnType<typeof setInterval> | undefined;
  let spinTimer: ReturnType<typeof setInterval> | undefined;
  let spin = 0;
  let cwd = process.cwd();
  let phase: Phase = "idle";
  // What to fall back to when a dialog closes; a dialog can open mid-run.
  let phaseBeforePrompt: Phase = "idle";
  let since = Date.now();
  let busy = false;
  let paintedTitle = "";
  let repaintTimer: ReturnType<typeof setTimeout> | undefined;
  let warnedModel = false;
  let label: Label | undefined;
  // Derived labels improve as a session goes on, so they are cached against the
  // branch leaf that produced them rather than persisted.
  let derivedCache: { leaf: string | null; text: string; source: Source } | undefined;

  const sessionId = () => state.ctx?.sessionManager.getSessionId() ?? "";
  const shortId = () => sessionId().slice(0, 8);

  const setPhase = (next: Phase) => {
    phase = next;
  };

  const startSpinner = () => {
    if (spinTimer) return;
    spinTimer = setInterval(() => {
      spin++;
      paint();
    }, SPIN_MS);
    spinTimer.unref?.();
  };

  const stopSpinner = () => {
    if (spinTimer) clearInterval(spinTimer);
    spinTimer = undefined;
  };

  const persist = () => {
    if (!label) return;
    pi.appendEntry<Label>(CUSTOM_TYPE, label);
  };

  /**
   * A session name we did not write is the user's choice through `/name`, and
   * it outranks anything this extension would generate.
   */
  const explicitName = () => {
    const name = pi.getSessionName();
    return name && name !== label?.text ? name : undefined;
  };

  const derive = (ctx: ExtensionContext): { text: string; source: Source } => {
    const leaf = ctx.sessionManager.getLeafId();
    if (derivedCache?.leaf === leaf) return derivedCache;
    let prompt = "";
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "message" || entry.message.role !== "user") continue;
      const text = userText(
        entry.message.content as string | Array<{ type: string; text?: string }>,
      );
      if (isSubstantive(text)) {
        prompt = text;
        break;
      }
    }
    derivedCache = prompt
      ? { leaf, text: cleanLabel(stripRequest(prompt)), source: "prompt" }
      : { leaf, text: basename(ctx.cwd) || ctx.cwd, source: "cwd" };
    return derivedCache;
  };

  const currentLabel = (ctx: ExtensionContext): { text: string; source: Source } => {
    const name = explicitName();
    if (name) return { text: name, source: "name" };
    if (label) return { text: label.text, source: label.source };
    return derive(ctx);
  };

  const renderTitle = (ctx: ExtensionContext) => {
    const { text } = currentLabel(ctx);
    const age = formatAge(Date.now() - since);
    const state = stateWord(phase);
    // A frozen frame, not the animation: the title is rewritten by the OS.
    const lead = busy || phase === "working" ? `${WORK_GLYPH} ` : "";
    return `${lead}${text} · ${shortPath(cwd)} · ${age}${state ? ` · ${state}` : ""}`;
  };

  const paint = () => {
    const ctx = state.ctx;
    if (!ctx) return;
    if (ctx.mode === "tui" && ctx.hasUI) {
      // Every tool call repaints; only rewrite the title when it changed, so the
      // titlebar does not flicker for a session that merely got older.
      const title = renderTitle(ctx);
      if (title !== paintedTitle) {
        paintedTitle = title;
        ctx.ui.setTitle(title);
      }
    }
    state.tui?.requestRender();
  };

  /**
   * Pi owns the title too (`π - <name> - <cwd>`) and rewrites it on startup and
   * whenever the session name changes, which includes our own auto-naming. Win
   * that race once per rename instead of on every render.
   */
  const repaintSoon = () => {
    if (repaintTimer) clearTimeout(repaintTimer);
    repaintTimer = setTimeout(() => {
      repaintTimer = undefined;
      paintedTitle = "";
      paint();
    }, 250);
    repaintTimer.unref?.();
  };

  const spinnerGlyph = () => SPINNER[spin % SPINNER.length]!;

  /**
   * One continuous line, inset like the footer's text: the leading and trailing
   * dashes stand in for its padding, and the detail is separated by the same
   * dashes instead of dots so the row reads as the top of the input box.
   * Detail is shed before the label is shortened.
   */
  const borderSides = (width: number, hidden: number, border: (text: string) => string) => {
    const ctx = state.ctx;
    if (!ctx) return { left: "", right: "" };
    const theme = ctx.ui.theme;
    const { text } = currentLabel(ctx);
    const stateText = stateWord(phase);
    // pi reports scrolled editor content as `↑ N more`; it describes the editor,
    // so it belongs next to the label rather than in the session detail.
    const hint = hidden > 0 ? ` ↑${hidden}` : "";
    const rows: string[][] = [
      [shortPath(cwd), stateText],
      // State outlives the path: it is the part that asks you to look.
      [stateText],
      [shortPath(cwd)],
      [],
    ];
    const working = busy || phase === "working";
    // pi's own shape: `── ⠋ Working`; the spinner takes the slot the label would.
    const lead = working ? `${border("──")} ${theme.fg("accent", spinnerGlyph())} ` : border("── ");
    const separator = border(" ── ");
    const tail = border(" ──");

    for (const row of rows) {
      const parts = row.filter(Boolean);
      const sized = parts.map((part) =>
        part === stateText
          ? theme.fg(stateText === "failed" ? "error" : "warning", part)
          : theme.fg("dim", part),
      );
      const right = parts.length > 0 ? ` ${sized.join(separator)}${tail}` : "";
      // lead + label + hint + space, then the detail, then at least one dash.
      const room = width - visibleWidth(lead) - visibleWidth(hint) - 2 - visibleWidth(right);
      if (room < MIN_LABEL_ROOM) continue;
      // The label wears the input's own border color (pi keys it to the
      // thinking level), so it reads as box chrome rather than prompt text.
      const painted = border(truncateToWidth(text, room, "…"));
      const label = state.hover === "label" ? theme.underline(painted) : painted;
      return { left: `${lead}${label}${theme.fg("dim", hint)} `, right };
    }
    return { left: "", right: "" };
  };

  const drawTop = (
    width: number,
    hidden: number,
    border: (text: string) => string,
  ): { line: string; regions: Region[] } => {
    const { left, right } = borderSides(width, hidden, border);
    const fill = Math.max(0, width - visibleWidth(left) - visibleWidth(right));
    return { line: left + (fill > 0 ? border("─".repeat(fill)) : "") + right, regions: [] };
  };

  const model = (ctx: ExtensionContext) => {
    const configured = process.env.PI_IDENTITY_MODEL || DEFAULT_MODEL;
    const slash = configured.indexOf("/");
    const found =
      slash > 0
        ? ctx.modelRegistry.find(configured.slice(0, slash), configured.slice(slash + 1))
        : undefined;
    if (found) return found;
    if (!warnedModel) {
      warnedModel = true;
      ctx.ui.notify(
        `identity: ${configured} is not in the catalog, using the active model`,
        "warning",
      );
    }
    return ctx.model;
  };

  const buildPrompt = (ctx: ExtensionContext, current: string) => {
    const prompts: string[] = [];
    const files: string[] = [];
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "message") continue;
      const message = entry.message;
      if (message.role === "user") {
        const text = userText(message.content as string | Array<{ type: string; text?: string }>);
        if (!isSubstantive(text)) continue;
        prompts.push(text);
      } else if (message.role === "assistant") {
        for (const block of message.content) {
          if (block.type !== "toolCall" || (block.name !== "edit" && block.name !== "write"))
            continue;
          const args = block.arguments as { path?: unknown; file_path?: unknown };
          const path = typeof args.path === "string" ? args.path : args.file_path;
          if (typeof path === "string") files.push(path);
        }
      }
    }

    const first = prompts[0];
    const recent = prompts.slice(-RECENT_PROMPTS);
    const lines = [`directory: ${shortPath(cwd)}`, `current label: ${current || "(none)"}`];
    if (files.length > 0) {
      lines.push(
        `files touched: ${[...new Set(files.map((path) => relative(cwd, path) || path))]
          .slice(-TOUCHED_FILES)
          .join(", ")}`,
      );
    }
    lines.push("requests:");
    if (first && !recent.includes(first)) lines.push(`- ${oneLine(first).slice(0, PROMPT_CHARS)}`);
    for (const prompt of recent) lines.push(`- ${oneLine(prompt).slice(0, PROMPT_CHARS)}`);
    return lines.join("\n");
  };

  const relabel = async (ctx: ExtensionContext, manual: boolean) => {
    if (busy) return;
    const name = explicitName();
    if (name) {
      if (manual) ctx.ui.notify(`identity: /name owns the label (${name})`, "warning");
      return;
    }
    if ((label?.calls ?? 0) >= CALL_CAP) {
      if (manual) ctx.ui.notify(`identity: label call cap (${CALL_CAP}) reached`, "warning");
      return;
    }
    const chosen = model(ctx);
    if (!chosen) {
      if (manual) ctx.ui.notify("identity: no model available for labeling", "warning");
      return;
    }

    busy = true;
    paint();
    try {
      const current = currentLabel(ctx).text;
      const response = await ctx.modelRegistry
        .streamSimple(
          chosen,
          {
            systemPrompt: SYSTEM,
            messages: [
              {
                role: "user",
                content: [{ type: "text", text: buildPrompt(ctx, current) }],
                timestamp: Date.now(),
              },
            ],
          },
          {
            // deepseek spends 60-70 tokens thinking before it writes the label,
            // and a smaller cap comes back as `length` with no text at all.
            maxTokens: 256,
            temperature: 0,
            timeoutMs: 12_000,
            // The opencode gateway routes on `x-opencode-session`, which pi
            // derives from this; without it the request fails with 400.
            sessionId: ctx.sessionManager.getSessionId(),
          },
        )
        .result();
      if (response.stopReason === "error" || response.stopReason === "aborted") {
        throw new Error(response.errorMessage ?? response.stopReason);
      }
      const reply = response.content
        .flatMap((block) => (block.type === "text" ? [block.text] : []))
        .join(" ");
      const text = cleanLabel(reply);
      if (text === "") throw new Error(`no text in reply (${response.stopReason})`);

      const named = label?.namedSession ?? false;
      label = {
        text,
        source: "model",
        at: Date.now(),
        calls: (label?.calls ?? 0) + 1,
        costUsd: (label?.costUsd ?? 0) + (response.usage?.cost?.total ?? 0),
        namedSession: named,
      };
      // `/resume` reads the session name, and it is the one place the label can
      // help before the window is even open. Set it once, only if untouched.
      if (!named) {
        pi.setSessionName(text);
        label.namedSession = true;
      }
      persist();
    } catch (error) {
      if (manual) {
        const reason = error instanceof Error ? error.message : String(error);
        ctx.ui.notify(`identity: relabel failed: ${reason}`, "error");
      }
    } finally {
      busy = false;
      paint();
    }
  };

  const quote = (path: string) =>
    /^[a-zA-Z0-9_\-./~:@]+$/.test(path) ? path : `'${path.replace(/'/g, `'\\''`)}'`;

  const resumeCommand = () => `cd ${quote(cwd)} && pi --session ${shortId()}`;
  const summary = (ctx: ExtensionContext) => {
    const { text, source } = currentLabel(ctx);
    const calls = label?.calls ?? 0;
    const persisted = ctx.sessionManager.getSessionFile();
    return [
      `${text}  (${source})`,
      `path: ${cwd}`,
      persisted
        ? `session: ${sessionId()}`
        : "session: ephemeral (--no-session), nothing to resume",
      `labels: ${calls} call${calls === 1 ? "" : "s"} · ${formatCost(label?.costUsd ?? 0)} (not in the footer total)`,
      persisted ? `resume: ${resumeCommand()}` : undefined,
    ]
      .filter(Boolean)
      .join("\n");
  };

  const setManual = (text: string): "set" | "empty" | "named" => {
    const cleaned = cleanLabel(text);
    if (cleaned === "") return "empty";
    if (explicitName()) return "named";
    label = {
      text: cleaned,
      source: "manual",
      at: Date.now(),
      calls: label?.calls ?? 0,
      costUsd: label?.costUsd ?? 0,
      namedSession: label?.namedSession ?? false,
    };
    derivedCache = undefined;
    persist();
    paint();
    return "set";
  };

  pi.registerCommand("header", {
    description: "Session identity: relabel, copy resume command, show path and id",
    handler: async (args, ctx) => {
      const trimmed = args.trim();
      if (trimmed) {
        const result = setManual(trimmed);
        if (result === "empty") ctx.ui.notify("identity: empty label ignored", "warning");
        if (result === "named")
          ctx.ui.notify("identity: /name owns the label, run /name to change it", "warning");
        return;
      }
      if (!ctx.hasUI) {
        ctx.ui.notify(summary(ctx), "info");
        return;
      }
      ctx.ui.notify(summary(ctx), "info");
      const choice = await ctx.ui.select("Session identity", [
        "Relabel now",
        "Copy resume command",
        "Set label…",
      ]);
      if (choice === "Relabel now") await relabel(ctx, true);
      else if (choice === "Copy resume command") {
        if (!ctx.sessionManager.getSessionFile()) {
          ctx.ui.notify("identity: this session is ephemeral (--no-session)", "warning");
          return;
        }
        await copyToClipboard(resumeCommand());
        ctx.ui.notify("identity: resume command copied", "info");
      } else if (choice === "Set label…") {
        const input = await ctx.ui.input("Session label", currentLabel(ctx).text);
        if (!input) return;
        const result = setManual(input);
        if (result === "named")
          ctx.ui.notify("identity: /name owns the label, run /name to change it", "warning");
      }
    },
  });

  pi.registerShortcut(SHORTCUT, {
    description: "Relabel this session",
    handler: (ctx) => relabel(ctx, true),
  });

  pi.on("session_start", (_event, ctx) => {
    state.ctx = ctx;
    cwd = ctx.cwd;
    phase = "idle";
    phaseBeforePrompt = "idle";
    since = Date.now();
    busy = false;
    paintedTitle = "";
    derivedCache = undefined;

    // The last persisted label on this branch wins, so a resumed session paints
    // instantly and without a model call.
    label = undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === CUSTOM_TYPE) {
        const data = entry.data as Partial<Label> | undefined;
        if (data && typeof data.text === "string" && data.text !== "") {
          label = {
            text: data.text,
            source: data.source ?? "model",
            at: data.at ?? Date.now(),
            calls: data.calls ?? 0,
            costUsd: data.costUsd ?? 0,
            namedSession: data.namedSession ?? false,
          };
        }
      }
    }

    if (timer) clearInterval(timer);
    timer = setInterval(paint, TICK_MS);
    // A print/RPC run must not be held open by a timer nobody looks at.
    timer.unref?.();
    paint();
    repaintSoon();
  });

  pi.on("agent_start", (_event, ctx) => {
    state.ctx = ctx;
    cwd = ctx.cwd;
    since = Date.now();
    setPhase("working");
    startSpinner();
    paint();
  });

  pi.on("agent_settled", (_event, ctx) => {
    state.ctx = ctx;
    since = Date.now();
    // Failure is sticky until the next run starts.
    setPhase(phase === "failed" ? "failed" : "idle");
    stopSpinner();
    paint();
  });

  pi.on("ui_prompt_start", (_event, ctx) => {
    state.ctx = ctx;
    since = Date.now();
    phaseBeforePrompt = phase;
    setPhase("waiting");
    paint();
  });

  pi.on("ui_prompt_end", (_event, ctx) => {
    state.ctx = ctx;
    since = Date.now();
    setPhase(phaseBeforePrompt);
    paint();
  });

  pi.on("message_end", (event, ctx) => {
    state.ctx = ctx;
    cwd = ctx.cwd;
    derivedCache = undefined;
    if (event.message.role === "assistant" && event.message.stopReason === "error") {
      setPhase("failed");
    }
    paint();
  });

  pi.on("tool_execution_end", (_event, ctx) => {
    state.ctx = ctx;
    paint();
  });

  pi.on("session_compact", (_event, ctx) => {
    state.ctx = ctx;
    derivedCache = undefined;
    // Compaction already paid for a summary, so the marginal label is cheap and
    // the work has usually moved on by the time one happens.
    void relabel(ctx, false);
    paint();
  });

  pi.on("session_info_changed", (_event, ctx) => {
    state.ctx = ctx;
    derivedCache = undefined;
    paint();
    repaintSoon();
  });

  pi.on("session_shutdown", () => {
    if (timer) clearInterval(timer);
    timer = undefined;
    stopSpinner();
    if (repaintTimer) clearTimeout(repaintTimer);
    repaintTimer = undefined;
    state.tui = undefined;
    if (state.ctx?.mode === "tui" && state.ctx.hasUI) {
      // Leave an honest title for the shell prompt that follows; the fish title
      // takes over from here, but a crash-free exit should not show a stale run.
      const { text } = currentLabel(state.ctx);
      state.ctx.ui.setTitle(`${text} · ${shortPath(cwd)}`);
    }
  });

  return { drawTop, relabel };
};
