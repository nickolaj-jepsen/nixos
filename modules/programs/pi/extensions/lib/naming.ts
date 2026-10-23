/**
 * What the naming calls read: the prompts you actually sent, and the files the
 * agent touched. A session label and a worktree branch name the same work, so
 * both are prompted with this and both answer in a handful of words.
 */
import { relative } from "node:path";
import type { Model } from "@earendil-works/pi-ai";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

// Hot and cheap, and routed through the gateway like everything else.
export const NAME_MODEL = "opencode-go/deepseek-v4.1-flash";
// deepseek spends 60-70 tokens thinking before it answers, and a smaller cap
// comes back as `length` with no text at all.
export const NAME_MAX_TOKENS = 256;
export const NAME_TIMEOUT_MS = 12_000;

const TRIVIAL =
  /^(yes|yeah|yep|ok|okay|sure|agreed?|agree|continue|go on|go ahead|proceed|do it|sounds good|perfect|thanks|lgtm|carry on|next)\b/i;

const userText = (content: string | Array<{ type: string; text?: string }>) =>
  typeof content === "string"
    ? content
    : content
        .flatMap((block) => (block.type === "text" && block.text ? [block.text] : []))
        .join("\n");

export const oneLine = (text: string) => text.replace(/\s+/g, " ").trim();

/** Short agreement replies are the bulk of a long session and say nothing new. */
const isSubstantive = (text: string) => {
  const trimmed = text.trim();
  const words = trimmed.split(/\s+/).length;
  return words >= 5 && !(words <= 8 && TRIVIAL.test(trimmed));
};

const substantivePrompts = (ctx: ExtensionContext) => {
  const prompts: string[] = [];
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "message" || entry.message.role !== "user") continue;
    const text = userText(entry.message.content as string | Array<{ type: string; text?: string }>);
    if (isSubstantive(text)) prompts.push(text);
  }
  return prompts;
};

/**
 * The session's requests, oldest first: the first substantive prompt and the
 * latest `recent`, each on one line cut to `chars`. Answers what the agent is
 * working on without growing with tool output.
 */
export const requests = (ctx: ExtensionContext, recent: number, chars: number) => {
  const prompts = substantivePrompts(ctx);
  const latest = prompts.slice(-recent);
  const picked = prompts[0] && !latest.includes(prompts[0]) ? [prompts[0], ...latest] : latest;
  return picked.map((prompt) => oneLine(prompt).slice(0, chars));
};

/** The first substantive prompt, whole: a deterministic name is cut from a sentence. */
export const firstRequest = (ctx: ExtensionContext) => substantivePrompts(ctx)[0];

// The deterministic name comes from a whole sentence, so drop the asking part.
const REQUEST_PREFIX = /^(?:(?:can|could|would|will) you (?:please )?|(?:please|help me|to) )/i;

/** `text` without the "can you please" that a named thing does not want. */
export const stripRequest = (text: string) => {
  let stripped = text.trim();
  for (let i = 0; i < 3; i++) {
    const next = stripped.replace(REQUEST_PREFIX, "");
    if (next === stripped) break;
    stripped = next;
  }
  return stripped;
};

/** The files the agent edited or wrote, relative to `cwd`, the last `limit` of them. */
export const touchedFiles = (ctx: ExtensionContext, cwd: string, limit: number) => {
  const files: string[] = [];
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "message" || entry.message.role !== "assistant") continue;
    for (const block of entry.message.content) {
      if (block.type !== "toolCall" || (block.name !== "edit" && block.name !== "write")) continue;
      const args = block.arguments as { path?: unknown; file_path?: unknown };
      const path = typeof args.path === "string" ? args.path : args.file_path;
      if (typeof path === "string") files.push(path);
    }
  }
  return [...new Set(files.map((path) => relative(cwd, path) || path))].slice(-limit);
};

/** The catalog entry named by `configured` ("provider/model"), if it is in the catalog. */
export const catalogModel = (ctx: ExtensionContext, configured: string) => {
  const slash = configured.indexOf("/");
  return slash > 0
    ? ctx.modelRegistry.find(configured.slice(0, slash), configured.slice(slash + 1))
    : undefined;
};

/** The naming model, falling back to the session's own when the catalog lacks it. */
export const namingModel = (ctx: ExtensionContext, configured: string): Model<any> | undefined =>
  catalogModel(ctx, configured) ?? ctx.model;
