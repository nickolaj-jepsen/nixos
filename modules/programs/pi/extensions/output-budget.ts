/**
 * Shrinks tool results to fit the active model's context window. Pi caps
 * bash/read output at 50KB (~12k tokens) for every model, which is over a third
 * of a 32k local model's window in one result. Large-context models get a
 * budget above that cap, so this only bites on small windows or a nearly full
 * context.
 *
 * `read` keeps the head and says where to continue; everything else keeps head
 * and tail (errors and summaries sit at the end) and saves the full text to a file.
 */
import { writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// Share of the window one result may take, and of the space still free.
const WINDOW_SHARE = 0.08;
const FREE_SHARE = 0.25;
const CHARS_PER_TOKEN = 4;
const MIN_CHARS = 4_000;
const HEAD_SHARE = 0.25;

function budgetChars(ctx: ExtensionContext): number {
  const window = ctx.model?.contextWindow;
  if (!window) return Infinity;
  let tokens = window * WINDOW_SHARE;
  const used = ctx.getContextUsage()?.tokens;
  if (used != null) tokens = Math.min(tokens, Math.max(0, window - used) * FREE_SHARE);
  return Math.max(MIN_CHARS, Math.floor(tokens * CHARS_PER_TOKEN));
}

export default function (pi: ExtensionAPI) {
  let saved = 0;

  pi.on("tool_result", (event, ctx) => {
    // Nested results go to the calling script, which reduces them itself.
    if (event.parentToolCallId) return;
    const texts = event.content.filter((part) => part.type === "text");
    const text = texts.map((part) => part.text).join("\n");
    const budget = budgetChars(ctx);
    if (text.length <= budget) return;

    let shrunk: string;
    if (event.toolName === "read") {
      const head = text.slice(0, budget);
      const kept = head.slice(0, head.lastIndexOf("\n") + 1) || head;
      const lines = kept.split("\n").length - 1;
      const { offset } = event.input as { offset?: number };
      shrunk = `${kept}\n[Cut to ${kept.length} of ${text.length} chars to fit the context window; read again with offset=${(offset ?? 1) + lines} to continue.]`;
    } else {
      const file = join(tmpdir(), `pi-tool-result-${process.pid}-${++saved}.txt`);
      writeFileSync(file, text);
      const head = Math.floor(budget * HEAD_SHARE);
      const tail = budget - head;
      shrunk = `${text.slice(0, head)}\n[… ${text.length - budget} chars cut to fit the context window; full output in ${file} …]\n${text.slice(-tail)}`;
    }
    const others = event.content.filter((part) => part.type !== "text");
    return { content: [{ type: "text", text: shrunk }, ...others] };
  });
}
