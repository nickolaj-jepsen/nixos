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
import { execFileSync } from "node:child_process";
import { basename } from "node:path";
import type { AssistantMessage, Model } from "@earendil-works/pi-ai";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { NAME_MAX_TOKENS, NAME_TIMEOUT_MS, oneLine, requests, touchedFiles } from "./naming.ts";

export type Fields = {
  /** Absent means the work has not moved on; the current label stands. */
  label?: string;
  /** Empty means "no step to show"; absent means "unchanged". */
  doing?: string;
  summary?: string;
  tags?: string[];
};

export const MAX_DOING = 32;
export const MAX_SUMMARY = 120;
export const MAX_TAGS = 3;

const RECENT_PROMPTS = 4;
const PROMPT_CHARS = 300;
const MAX_FILES = 6;
const MAX_COMMANDS = 5;
const COMMAND_CHARS = 48;
// A branch moves a few times a day and every call would otherwise pay a subprocess.
const GIT_TTL_MS = 30_000;

const SYSTEM = `You keep a coding session's identity current for the person working in it.
Answer with exactly these four lines, in this order, and nothing else:
label: 2-6 lowercase words naming what the work is about
doing: at most 8 words for the step in flight, or empty
summary: one sentence of at most 20 words about the session so far
tags: up to three of bugfix feature refactor test docs deps ci perf chore

- The label names the work, never that you agreed to something.
- Repeat the current label word for word when the work has not moved on.
- doing names the step, not the subject: "stuck on the retry test", not "auth work".
- The branch is a hint about the work, never the label on its own.
- No quotes, no preamble, no commentary, no other lines.`;

type GitContext = { repo: string; branch?: string };

let gitCache: { cwd: string; at: number; value: GitContext } | undefined;

/** The repository and checked-out branch, or the directory name outside git. */
const gitContext = (cwd: string): GitContext => {
  if (gitCache && gitCache.cwd === cwd && Date.now() - gitCache.at < GIT_TTL_MS) {
    return gitCache.value;
  }
  let value: GitContext = { repo: basename(cwd) || cwd };
  try {
    const [top, head] = execFileSync(
      "git",
      ["rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"],
      { cwd, encoding: "utf8", timeout: 1000, stdio: ["ignore", "pipe", "ignore"] },
    )
      .trim()
      .split("\n");
    if (top) value = { repo: basename(top), branch: head && head !== "HEAD" ? head : undefined };
  } catch {
    // Not a checkout, or git is missing: the directory still says which project this is.
  }
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
};

/** The digest the model reads: enough to name the work, small enough to pay for every turn. */
export const buildPrompt = (ctx: ExtensionContext, input: Input) => {
  const { repo, branch } = gitContext(ctx.cwd);
  const lines = [`repo: ${repo}${branch ? ` · branch: ${branch}` : ""}`];
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
  return lines.join("\n");
};

// Tolerates a model that answers in a list or bolds its keys, which small ones do.
const LINE = /^[\s>*#-]*\**\s*(label|doing|summary|tags)\s*\**\s*:\s*\**\s*(.*?)\s*\**\s*$/i;

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
        // deepseek spends 60-70 tokens thinking before it answers, and a smaller
        // cap comes back as `length` with no text at all.
        maxTokens: NAME_MAX_TOKENS,
        temperature: 0,
        timeoutMs: NAME_TIMEOUT_MS,
        // The opencode gateway routes on `x-opencode-session`, which pi derives
        // from this; without it the request fails with 400.
        sessionId: ctx.sessionManager.getSessionId(),
        signal,
      },
    )
    .result();
