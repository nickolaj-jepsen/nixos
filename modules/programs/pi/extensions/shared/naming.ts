/**
 * The prompts you actually sent, for guardian to read.
 */
import { contentText } from "@earendil-works/pi-ai";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

// Bare acknowledgements only. A word count cannot tell "sounds good, but make
// it async" from "sounds good", and dropping that sentence silently hides the
// change of direction.
const ACK = new Set(
  "ok okay k yes yeah yep yup sure continue proceed thanks thank ty lgtm agreed agree perfect great nice cool fine good sounds right correct carry on next go ahead do it please".split(
    " ",
  ),
);

/** True when `text` only agrees, continues or thanks: nothing to re-read the work for. */
const isAcknowledgement = (text: string) => {
  const words = text.toLowerCase().match(/[a-z']+/g) ?? [];
  return words.length > 0 && words.length <= 3 && words.every((word) => ACK.has(word));
};

export const oneLine = (text: string) => text.replace(/\s+/g, " ").trim();

/** `text` cut to `max` characters, the last one an ellipsis. */
export const clip = (text: string, max: number) =>
  text.length > max ? `${text.slice(0, max - 1)}…` : text;

const sessionPrompts = (ctx: ExtensionContext) => {
  const prompts: string[] = [];
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "message" || entry.message.role !== "user") continue;
    const text = contentText(entry.message.content);
    if (!isAcknowledgement(text)) prompts.push(text);
  }
  return prompts;
};

/**
 * The session's requests, oldest first: the first real prompt and the latest
 * `recent`, each on one line cut to `chars`. Answers what the agent is working
 * on without growing with tool output.
 */
export const requests = (ctx: ExtensionContext, recent: number, chars: number) => {
  const prompts = sessionPrompts(ctx);
  const latest = prompts.slice(-recent);
  const picked = prompts[0] && !latest.includes(prompts[0]) ? [prompts[0], ...latest] : latest;
  return picked.map((prompt) => oneLine(prompt).slice(0, chars));
};
