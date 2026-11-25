import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { setTimeout } from "node:timers/promises";
import { fileURLToPath } from "node:url";

/*
 * Read-only sibling terminal for one Pi child agent. It never reads a model,
 * forwards input or trusts the snapshot: every field below is untrusted text
 * and goes through `bounded` before it can reach the terminal.
 */

const KNOWN_STATES = ["working", "waiting", "idle", "failed", "interrupted", "skipped"];
const KNOWN = new Set(KNOWN_STATES);

/** The lifecycle in words; `waiting` is about dependencies, not the reader. */
const EXPLANATIONS = {
  working: "running its turn; output appears in the parent Pi session",
  waiting: "waiting on its dependencies, not on you",
  idle: "completed its turn",
  failed: "failed; the error is reported in the parent Pi session",
  interrupted: "interrupted before completing",
  skipped: "skipped and never started",
  unknown: "unrecognized state; waiting for the next update",
};

// Any CSI (private and colon forms too), then OSC, DCS, PM and APC strings up to BEL or ST.
const TERMINAL_SEQUENCE = /\x1b\[[0-?]*[ -/]*[@-~]|\x1b[\]P^_][\s\S]*?(?:\x07|\x1b\\)/g;
// C0/C1 controls, bidi overrides and isolates, zero-width characters.
const UNSAFE = /[\x00-\x1f\x7f-\x9f\u061c\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/g;

const DEFAULT_COLUMNS = 80;
const DEFAULT_ROWS = 24;
const MIN_COLUMNS = 20;
const MAX_COLUMNS = 400;
const MIN_ROWS = 6;
const MAX_ROWS = 200;
const NAME_LIMIT = 160;
const FIELD_LIMIT = 240;
const SHORT_LIMIT = 80;
const HISTORY_LIMIT = 8;
// A hostile array can be long; only its tail is ever read.
const HISTORY_SCAN = 64;
// The bridge writes a tiny snapshot; anything bigger is not one.
const MAX_FILE_CHARS = 64 * 1024;
const POLL_MS = 300;
// The clock lines stay honest without a rewrite of the snapshot, so the body is
// redrawn about once a second; the protocol head is not, or herdr sees churn.
const CLOCK_MS = 1000;
const CLEAR = "\x1b[2J\x1b[H";

/** One untrusted value as bounded single-line text; anything exotic becomes "". */
const bounded = (value, limit) => {
  const raw =
    typeof value === "string" || typeof value === "number" || typeof value === "boolean"
      ? String(value)
      : "";
  // toWellFormed replaces lone surrogates, which some terminals draw as garbage.
  let text = typeof raw.toWellFormed === "function" ? raw.toWellFormed() : raw;
  text = text.replace(TERMINAL_SEQUENCE, " ").replace(UNSAFE, " ");
  text = text.replace(/\s+/g, " ").trim();
  const chars = Array.from(text);
  return chars.length > limit ? chars.slice(0, limit).join("") : text;
};

// No names/prompts can inject terminal controls. Keep the status title bounded.
export const cleanName = (name) => bounded(name, NAME_LIMIT);

// A Map, not an object literal: `statusOf("constructor")` must not find a
// prototype member and report it as a protocol state.
const STATUS = new Map([
  ["working", "working"],
  ["waiting", "idle"],
  ["idle", "done"],
  ["failed", "error"],
  ["interrupted", "idle"],
  ["skipped", "idle"],
]);

export const statusOf = (state) => STATUS.get(state) ?? "idle";

// Wide code points (CJK, Hangul, fullwidth forms, emoji) occupy two cells.
const WIDE =
  /[\u1100-\u115f\u2e80-\u303e\u3041-\u33ff\u3400-\u4dbf\u4e00-\u9fff\ua000-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]|[\u{1f000}-\u{1faff}\u{20000}-\u{3fffd}]/u;
const cellWidth = (char) => (WIDE.test(char) ? 2 : 1);
const cellsOf = (text) => {
  let width = 0;
  for (const char of text) width += cellWidth(char);
  return width;
};

const truncate = (text, width) => {
  if (width <= 0) return "";
  if (cellsOf(text) <= width) return text;
  if (width === 1) return "…";
  let used = 0;
  let out = "";
  for (const char of text) {
    const cells = cellWidth(char);
    if (used + cells > width - 1) break;
    out += char;
    used += cells;
  }
  return `${out}…`;
};

const clampInt = (value, min, max, fallback) =>
  typeof value === "number" && Number.isFinite(value)
    ? Math.min(max, Math.max(min, Math.trunc(value)))
    : fallback;

const normalizeView = (view) => {
  const source = view && typeof view === "object" ? view : {};
  return {
    columns: clampInt(source.columns, MIN_COLUMNS, MAX_COLUMNS, DEFAULT_COLUMNS),
    rows: clampInt(source.rows, MIN_ROWS, MAX_ROWS, DEFAULT_ROWS),
    now: typeof source.now === "number" && Number.isFinite(source.now) ? source.now : Date.now(),
  };
};

const timestamp = (value) =>
  typeof value === "number" && Number.isFinite(value) && value > 0 && value <= 8.64e15
    ? value
    : undefined;

const formatDuration = (ms) => {
  const total = Math.floor(Math.max(0, ms) / 1000);
  if (total < 60) return `${total}s`;
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  if (minutes < 60) return seconds > 0 ? `${minutes}m ${seconds}s` : `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  const restMinutes = minutes % 60;
  if (hours < 24) return restMinutes > 0 ? `${hours}h ${restMinutes}m` : `${hours}h`;
  const days = Math.floor(hours / 24);
  const restHours = hours % 24;
  return restHours > 0 ? `${days}d ${restHours}h` : `${days}d`;
};

const formatAgo = (ms) => {
  const elapsed = Math.max(0, ms);
  return elapsed < 1000 ? "just now" : `${formatDuration(elapsed)} ago`;
};

/** Only a tail of the session id, and only when it is the sole identity left. */
const sessionLabel = (sessionId) => {
  const text = bounded(sessionId, SHORT_LIMIT);
  if (!text) return "agent";
  const chars = Array.from(text);
  return `agent ${chars.slice(Math.max(0, chars.length - 6)).join("")}`;
};

/** The protocol title and status herdr reads; the payload is sanitized first. */
const protocolHead = (name, state, status) => {
  const title = cleanName(name) || "agent";
  // A fixed vocabulary value, or the word "unknown": never raw snapshot text.
  const lifecycle = KNOWN.has(state) ? state : "unknown";
  const msg = Buffer.from(`${title}: ${lifecycle}`, "utf8").toString("base64");
  return `\x1b]0;Pi agent: ${title}\x07` + `\x1b]7501;state=${status}:app=pi:msg=${msg}\x1b\\`;
};

const historyOf = (agent, now) => {
  if (!Array.isArray(agent.history)) return [];
  const lines = [];
  // Newest last, and only the recent tail of a possibly huge array.
  for (const entry of agent.history.slice(-HISTORY_SCAN)) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    if (!KNOWN.has(entry.state)) continue;
    const at = timestamp(entry.at);
    if (at === undefined) continue;
    lines.push(`  ${formatAgo(now - at).padEnd(12, " ")} ${entry.state}`);
  }
  return lines.slice(-HISTORY_LIMIT);
};

const fitLine = (line, width) => {
  const text = truncate(line, width);
  return text + " ".repeat(Math.max(0, width - cellsOf(text)));
};

// `startedAt` is when the bridge first observed the agent, not when its task
// started, so the label must not promise a runtime; `updatedAt` is the last
// observed state transition.
const screenOf = (agent, view) => {
  const { columns, rows, now } = normalizeView(view);
  const a = agent && typeof agent === "object" && !Array.isArray(agent) ? agent : {};
  const state = KNOWN.has(a.state) ? a.state : "unknown";
  const status = statusOf(state);
  const id = bounded(a.id, SHORT_LIMIT);
  const name = cleanName(a.name) || id || sessionLabel(a.sessionId);

  const details = [];
  details.push(`Agent: ${name}${id && id !== name ? ` (id ${id})` : ""}`);
  details.push(`State: ${state} — ${EXPLANATIONS[state]}`);
  const cwd = bounded(a.cwd, FIELD_LIMIT);
  if (cwd) details.push(`Directory: ${cwd}`);
  const task = bounded(a.task, FIELD_LIMIT);
  if (task) details.push(`Task: ${task}`);
  const model = bounded(a.model, SHORT_LIMIT);
  if (model) details.push(`Model: ${model}`);
  const startedAt = timestamp(a.startedAt);
  if (startedAt !== undefined) details.push(`Observed for: ${formatDuration(now - startedAt)}`);
  const updatedAt = timestamp(a.updatedAt);
  if (updatedAt !== undefined) details.push(`Changed: ${formatAgo(now - updatedAt)}`);

  const history = historyOf(a, now);
  const badge = state.toUpperCase();
  const nameWidth = Math.max(0, columns - badge.length - 1);
  const left = truncate(name, nameWidth);
  const gap = " ".repeat(Math.max(1, columns - badge.length - cellsOf(left)));
  const header = left + gap + badge;
  const footer = [
    "",
    "Read-only Pi agent monitor.",
    "Inspect or message it in the parent Pi /agents.",
  ];

  // Every row is accounted for and the last viewport row is reserved, so the
  // trailing newline cannot scroll an exactly full-height frame.
  const body = rows - 3;
  const footerLines = body >= footer.length + 2 ? footer : [];
  let rest = body - footerLines.length;
  const detailLines = details.slice(0, Math.max(0, rest));
  rest -= detailLines.length;
  // When rows are tight, keep the newest transitions, not the oldest of the tail.
  const historyLines =
    rest >= 3 && history.length > 0
      ? ["", "Recent state changes", ...history.slice(-(rest - 2))]
      : [];

  const lines = [header, "─".repeat(columns), ...detailLines, ...historyLines, ...footerLines];
  return {
    head: protocolHead(name, a.state, status),
    // Exact-width lines let a clock tick redraw over the old frame without a clear.
    body: `${lines.map((line) => fitLine(line, columns)).join("\n")}\n`,
  };
};

export function renderMonitor(agent, view) {
  const { head, body } = screenOf(agent, view);
  return head + CLEAR + body;
}

/** A malformed snapshot still gets a bounded, honest screen and no crash. */
function unreadableScreen(view) {
  const { columns, rows } = normalizeView(view);
  const lines = [
    "Unreadable agent state",
    "",
    "The monitor keeps watching; the parent session may be restarting.",
    "Read-only Pi agent monitor.",
  ];
  return {
    head: protocolHead("agent", "unknown", statusOf("unknown")),
    // Same reserved last row as a normal frame.
    body: `${lines
      .slice(0, Math.max(1, rows - 1))
      .map((line) => fitLine(line, columns))
      .join("\n")}\n`,
  };
}

/** True when the rendered text changes with the clock alone. */
const clockDriven = (agent) => {
  if (!agent || typeof agent !== "object") return false;
  if (timestamp(agent.startedAt) !== undefined || timestamp(agent.updatedAt) !== undefined) {
    return true;
  }
  return Array.isArray(agent.history) && agent.history.length > 0;
};

const parseSnapshot = (content) => {
  if (content.length > MAX_FILE_CHARS) return undefined;
  let value;
  try {
    value = JSON.parse(content);
  } catch {
    return undefined;
  }
  return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
};

/** Terminal size, or safe defaults when stdout is a pipe (tests, hc --bg). */
const viewportOf = () => ({
  columns: process.stdout.columns,
  rows: process.stdout.rows,
});

const write = (text) => {
  try {
    process.stdout.write(text);
  } catch {
    // The terminal is already gone; nothing left to say.
  }
};

export async function monitor(file, parentPid) {
  // Never execute or forward text sent to this terminal.
  process.stdin.resume();
  process.stdin.on("data", () => {});
  process.stdin.on("error", () => {});
  process.stdout.on("error", () => {});

  const pid = Number(parentPid);
  const hasParent = Number.isInteger(pid) && pid > 0;
  const alive = () => {
    try {
      process.kill(pid, 0);
      return true;
    } catch (error) {
      // EPERM still means the parent exists, just as another user.
      return error?.code === "EPERM";
    }
  };

  let stopped = false;
  const controller = new AbortController();
  const stop = () => {
    stopped = true;
    controller.abort();
  };
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) process.once(signal, stop);

  let lastContent;
  let lastViewport;
  let lastAgent;
  let drawnAt = 0;
  try {
    while (!stopped && !(hasParent && !alive())) {
      const viewport = viewportOf();
      const size = `${viewport.columns}x${viewport.rows}`;
      let content;
      try {
        content = await readFile(file, "utf8");
      } catch {
        // The bridge removes the file on cleanup, and writes via rename, so a
        // read error here means the monitor's lifetime is over.
        break;
      }
      const key = content.length > MAX_FILE_CHARS ? `oversized:${content.length}` : content;
      if (key !== lastContent || size !== lastViewport) {
        const agent = parseSnapshot(content);
        const frame = agent ? screenOf(agent, viewport) : unreadableScreen(viewport);
        write(frame.head + CLEAR + frame.body);
        // A malformed snapshot is shown once, not on every poll.
        lastContent = key;
        lastViewport = size;
        lastAgent = agent;
        drawnAt = Date.now();
      } else if (lastAgent && clockDriven(lastAgent) && Date.now() - drawnAt >= CLOCK_MS) {
        // Clock-only redraw: the body is exactly viewport-wide, so home is enough
        // and no OSC status is repeated for a mere tick.
        write("\x1b[H" + screenOf(lastAgent, viewport).body);
        drawnAt = Date.now();
      }
      try {
        await setTimeout(POLL_MS, undefined, { signal: controller.signal });
      } catch {
        break;
      }
    }
  } finally {
    for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) process.removeListener(signal, stop);
    write("\x1b]7501;state=clear\x1b\\");
    process.stdin.pause();
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await monitor(process.argv[2], process.argv[3]);
}
