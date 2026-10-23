/**
 * Shrinks tool results to fit the active model's context window. Pi caps
 * bash/read output at 50KB (~12k tokens) for every model, which is over a third
 * of a 32k local model's window in one result. Large-context models get a
 * budget above that cap, so this only bites on small windows or a nearly full
 * context.
 *
 * `read` keeps the head and says where to continue, or, inside a line longer
 * than the budget, how to page through it with bash; everything else keeps head
 * and tail (errors and summaries sit at the end) and points at the full text.
 */
import { writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  type ExtensionAPI,
  type ExtensionContext,
  isBashToolResult,
} from "@earendil-works/pi-coding-agent";

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
      const { path, offset } = event.input as { path?: string; offset?: number };
      const line = offset ?? 1;
      const end = head.lastIndexOf("\n") + 1;
      if (end > 0) {
        const kept = head.slice(0, end);
        const lines = kept.split("\n").length - 1;
        shrunk = `${kept}\n[Cut to ${kept.length} of ${text.length} chars to fit the context window; read again with offset=${line + lines} to continue.]`;
      } else {
        // Offset paging can't move inside one line, so the read notice would loop on the same cut.
        shrunk = `${head}\n[Line ${line} of ${path} is longer than the ${budget}-char budget; showing its first ${budget} chars. Page through it with bash, e.g. sed -n '${line}p' ${path} | tail -c +${budget + 1} | head -c ${budget}, or grep for what you need.]`;
      }
    } else {
      // A truncated bash result is already pi's cut; pi saved the real full output.
      let file = isBashToolResult(event) ? event.details?.fullOutputPath : undefined;
      if (!file) {
        file = join(tmpdir(), `pi-tool-result-${process.pid}-${++saved}.txt`);
        writeFileSync(file, text);
      }
      const head = Math.floor(budget * HEAD_SHARE);
      const tail = budget - head;
      shrunk = `${text.slice(0, head)}\n[… ${text.length - budget} chars cut to fit the context window; full output in ${file} …]\n${text.slice(-tail)}`;
    }
    const others = event.content.filter((part) => part.type !== "text");
    return { content: [{ type: "text", text: shrunk }, ...others] };
  });
}
