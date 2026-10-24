/**
 * One model call that keeps a session's identity current: the name it goes by,
 * the step in flight, a sentence about the work, and its tags.
 *
 * It runs at turn start, in parallel with the run, so a name is ready by the
 * time anyone looks at the border. Answers arrive as `key: value` lines rather
 * than JSON: a missing key means "unchanged", a malformed line costs only
 * itself, and there is no schema for a small model to lose its way in.
 *
 * What it reads is a digest of the work, not the transcript. Prompts, the files
 * the agent touched and the commands it ran say what the session is about for a
 * few hundred tokens; the raw tool output would say less for thousands.
 */
import { execFile } from "node:child_process";
import { basename } from "node:path";
import type { AssistantMessage, Model } from "@earendil-works/pi-ai";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { NAME_TIMEOUT_MS, oneLine, requests, touchedFiles } from "./naming.ts";

export type Fields = {
  /** Absent means the work has not moved on; the current label stands. */
  label?: string;
  /** Empty means "no step to show"; absent means "unchanged". */
  doing?: string;
  summary?: string;
  tags?: string[];
  /** What the finished turn wants from the person, when it wants anything. */
  ask?: string;
  /** The person's likely answer to `ask`, for the row under the input. */
  reply?: string;
  /** How the finished turn ended; absent when the model left it out. */
  state?: TurnState;
};

/** How a finished turn ended: it did the work, it needs the person, or it could not finish. */
export type TurnState = "done" | "blocked" | "failed";
const TURN_STATES: readonly string[] = ["done", "blocked", "failed"];

/** Session entries the identity extension appends; the last one on a branch is current. */
export const IDENTITY_ENTRY = "identity_label";

/** `pi.events` channel for each sidecar answer, so other extensions can use it without asking again. */
export const SIDECAR_CHANNEL = "fireproof:sidecar";

/**
 * One sidecar outcome. `settle` fires once per finished turn even when no call
 * was made (`asked: false`), so a listener waiting on the turn never has to time out.
 */
export type SidecarUpdate = {
  sessionId: string;
  moment: "start" | "settle";
  asked: boolean;
  label?: string;
  summary?: string;
  doing?: string;
  state?: TurnState;
  ask?: string;
};

export const MAX_DOING = 32;
export const MAX_SUMMARY = 120;
export const MAX_ASK = 110;
export const MAX_REPLY = 240;
export const MAX_TAGS = 3;
/** Headroom for seven lines, not a target: only the tokens emitted are billed. */
// The model reasons before answering and a reasoning model will not be told
// otherwise (468 of 512 in testing), so the cap has to clear the thinking that
// the fields need, or the reply comes back as `length` with no text at all.
const MAX_TOKENS = 1024;

const RECENT_PROMPTS = 4;
const PROMPT_CHARS = 300;
const MAX_FILES = 6;
const MAX_COMMANDS = 5;
const COMMAND_CHARS = 48;
// A branch moves a few times a day and every call would otherwise pay a subprocess.
const GIT_TTL_MS = 30_000;

const SYSTEM = `You keep a coding session's identity current for the person working in it.
Answer with exactly these seven lines, in this order, and nothing else:
label: 2-6 lowercase words naming what the work is about
doing: at most 8 words for the step in flight, or empty
summary: one sentence of at most 20 words about the session so far
tags: up to three of bugfix feature refactor test docs deps ci perf chore
state: done, blocked or failed for the assistant turn, or empty
ask: what the assistant turn needs from the person, or empty
reply: what the person would most likely type to answer ask, or empty

- The label names the work, never that you agreed to something.
- Repeat the current label word for word when the work has not moved on.
- doing names the step, not the subject: "stuck on the retry test", not "auth work".
- The branch is a hint about the work, never the label on its own.
- Fill state, ask and reply only from the assistant turn below. Leave all three
  empty when there is no such turn.
- state: done when the turn finished what was asked, blocked when it waits on a
  decision or answer from the person, failed when it gave up or says the work
  does not work yet. A turn with an ask is blocked.
- ask is a request, not a summary: "keep the old fixture?" not "asked about the fixture".
  Leave it empty when the turn asks for nothing.
- reply predicts what the person would type, not what you think they should
  say: their words, their length and their tone, as in the requests above.
  Leave it empty when you cannot tell which way they would answer.
- No quotes, no preamble, no commentary, no other lines.`;

type GitContext = { repo: string; branch?: string };

let gitCache: { cwd: string; at: number; value: GitContext } | undefined;

/** The repository and checked-out branch, or the directory name outside git. */
export const gitContext = async (cwd: string): Promise<GitContext> => {
  if (gitCache && gitCache.cwd === cwd && Date.now() - gitCache.at < GIT_TTL_MS) {
    return gitCache.value;
  }
  const stdout = await new Promise<string>((resolve) =>
    execFile(
      "git",
      ["rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"],
      { cwd, timeout: 1000 },
      // Not a checkout, or git is missing: the directory still says which project this is.
      (error, out) => resolve(error ? "" : out),
    ),
  );
  const [top, head] = stdout.trim().split("\n");
  const value: GitContext = top
    ? { repo: basename(top), branch: head && head !== "HEAD" ? head : undefined }
    : { repo: basename(cwd) || cwd };
  gitCache = { cwd, at: Date.now(), value };
  return value;
};

/** The last `limit` shell commands of the branch, with whether each one failed. */
const commands = (ctx: ExtensionContext, limit: number) => {
  const failed = new Map<string, boolean>();
  const calls: Array<{ id: string; text: string }> = [];
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "message") continue;
    const message = entry.message;
    if (message.role === "toolResult") {
      failed.set(message.toolCallId, message.isError);
      continue;
    }
    if (message.role !== "assistant") continue;
    for (const block of message.content) {
      if (block.type !== "toolCall" || block.name !== "bash") continue;
      const command = (block.arguments as { command?: unknown }).command;
      if (typeof command !== "string") continue;
      const line = command.split("\n").find((part) => part.trim() !== "") ?? "";
      calls.push({ id: block.id, text: oneLine(line).slice(0, COMMAND_CHARS) });
    }
  }
  // Only the tail is cut: a command's outcome is what the name has to account for.
  return calls.slice(-limit).map((call) => {
    const outcome = failed.get(call.id);
    return `${call.text}${outcome === undefined ? "" : outcome ? " (failed)" : " (ok)"}`;
  });
};

/** What the border shows now, so the model can repeat it, extend it and re-tag it. */
export type Input = {
  label?: string;
  summary?: string;
  tags?: readonly string[];
  /** Set when a turn just finished: the assistant's closing words are worth reading. */
  settle?: boolean;
};

/** The last assistant text of the branch, on one line, cut to a glance. */
const closingWords = (ctx: ExtensionContext) => {
  for (const entry of [...ctx.sessionManager.getBranch()].reverse()) {
    if (entry.type !== "message" || entry.message.role !== "assistant") continue;
    const text = entry.message.content
      .flatMap((block) => (block.type === "text" ? [block.text] : []))
      .join(" ");
    if (text.trim() !== "") return oneLine(text).slice(0, 500);
  }
  return undefined;
};

/** The digest the model reads: enough to name the work, small enough to pay for every turn. */
export const buildPrompt = async (ctx: ExtensionContext, input: Input) => {
  const git = gitContext(ctx.cwd);
  const lines: string[] = [];
  if (input.label) lines.push(`current label: ${input.label}`);
  if (input.summary) lines.push(`previous summary: ${input.summary}`);
  if (input.tags?.length) lines.push(`tags so far: ${input.tags.join(", ")}`);
  const files = touchedFiles(ctx, ctx.cwd, MAX_FILES);
  if (files.length > 0) lines.push(`files touched: ${files.join(", ")}`);
  const ran = commands(ctx, MAX_COMMANDS);
  if (ran.length > 0) lines.push(`commands: ${ran.join("; ")}`);
  lines.push(
    "requests:",
    ...requests(ctx, RECENT_PROMPTS, PROMPT_CHARS).map((prompt) => `- ${prompt}`),
  );
  const said = input.settle ? closingWords(ctx) : undefined;
  if (said) lines.push(`assistant said: ${said}`);
  // Awaited last: the session's ctx goes stale if it shuts down meanwhile.
  const { repo, branch } = await git;
  return [`repo: ${repo}${branch ? ` · branch: ${branch}` : ""}`, ...lines].join("\n");
};

// Tolerates a model that answers in a list or bolds its keys, which small ones do.
const LINE =
  /^[\s>*#-]*\**\s*(label|doing|summary|tags|state|ask|reply)\s*\**\s*:\s*\**\s*(.*?)\s*\**\s*$/i;

const stripQuotes = (text: string) => text.replace(/^["'`“”‘’]+|["'`“”‘’]+$/g, "").trim();

/** The fields in `reply`; a key the model omitted is left for the caller to keep. */
export const parseFields = (reply: string): Fields => {
  const fields: Fields = {};
  for (const line of reply.split("\n")) {
    const match = LINE.exec(line);
    if (!match) continue;
    const key = match[1].toLowerCase();
    const value = stripQuotes(oneLine(match[2]));
    if (key === "label") {
      if (value) fields.label = value;
    } else if (key === "doing") {
      fields.doing = value;
    } else if (key === "summary") {
      if (value) fields.summary = value.slice(0, MAX_SUMMARY);
    } else if (key === "state") {
      const state = value.toLowerCase();
      if (TURN_STATES.includes(state)) fields.state = state as TurnState;
    } else if (key === "ask") {
      fields.ask = value.slice(0, MAX_ASK);
    } else if (key === "reply") {
      fields.reply = value.slice(0, MAX_REPLY);
    } else {
      fields.tags = value
        .split(/[,\s]+/)
        .map((tag) => tag.toLowerCase().replace(/[^a-z0-9-]/g, ""))
        .filter(Boolean)
        .slice(0, MAX_TAGS);
    }
  }
  return fields;
};

/** Asks the sidecar; the caller owns the abort signal, the timeout and the ledger entry. */
export const ask = async (
  ctx: ExtensionContext,
  model: Model<any>,
  prompt: string,
  signal: AbortSignal,
): Promise<AssistantMessage> =>
  ctx.modelRegistry
    .streamSimple(
      model,
      {
        systemPrompt: SYSTEM,
        messages: [
          {
            role: "user",
            content: [{ type: "text", text: prompt }],
            timestamp: Date.now(),
          },
        ],
      },
      {
        // Seven short lines, and nothing worth thinking about: a model that reasons
        // here spends the whole budget on it and returns no text at all.
        maxTokens: MAX_TOKENS,
        reasoning: "minimal",
        temperature: 0,
        timeoutMs: NAME_TIMEOUT_MS,
        // The opencode gateway routes on `x-opencode-session`, which pi derives
        // from this; without it the request fails with 400.
        sessionId: ctx.sessionManager.getSessionId(),
        signal,
      },
    )
    .result();
