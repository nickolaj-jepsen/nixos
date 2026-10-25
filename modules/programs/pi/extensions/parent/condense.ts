/**
 * Draws a collapsed tool result as one line: status, duration, size and, for a
 * shell command, the line it ended on. Pi's own collapsed form previews five to
 * twenty lines per result, which is where most of the transcript's height goes.
 *
 * Every other case delegates through `next()`: expansion (ctrl+o, or the chip on
 * the editor's top border), streaming output and failures keep pi's rendering.
 * So do the tools whose result body is the payload rather than a report about
 * work done.
 */
import { contentText } from "@earendil-works/pi-ai";
import type { ExtensionAPI, Theme, ToolRenderers } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";

type RenderResult = NonNullable<ToolRenderers["renderResult"]>;
type Result = Parameters<RenderResult>[0];
type Context = Parameters<RenderResult>[3];

const KEEP_BODY = new Set([
  // The diff is how the change gets checked.
  "edit",
  "write",
  // A hidden question is a bug.
  "ask_user_question",
]);

// Only a command ends on a line worth quoting; in a file or a result list the
// last line is the middle of the thing, not a verdict.
const QUOTE_LAST_LINE = new Set(["bash"]);

// Nerd Font range again: U+2713 is not in Hack Nerd Font, so fontconfig would
// pick the glyph's width instead of the font's.
const CHECK = "\uf00c";

const showsImage = (result: Result) =>
  (result.content ?? []).some((block) => block.type === "image");

const seconds = (ms: number) =>
  ms < 1000 ? `${Math.round(ms)}ms` : `${Math.round(ms / 100) / 10}s`;

/** One line whatever it says: a wrapped summary would defeat the point. */
const oneLine = (text: string) => ({
  render: (width: number) => [truncateToWidth(text, Math.max(1, width), "…")],
  invalidate: () => {},
});

const summarize = (toolName: string, result: Result, theme: Theme, context: Context) => {
  const body = contentText(result.content ?? []).trimEnd();
  const separator = theme.fg("dim", " · ");
  const meta: string[] = [];
  if (context.durationMs !== undefined) meta.push(theme.fg("dim", seconds(context.durationMs)));
  if (body !== "") {
    const lines = body.split("\n").length;
    meta.push(theme.fg("dim", `${lines} ${lines === 1 ? "line" : "lines"}`));
  }
  // The check joins the first fact instead of sitting behind its own separator.
  const parts = [theme.fg("success", CHECK) + (meta.length > 0 ? ` ${meta.join(separator)}` : "")];
  const last = QUOTE_LAST_LINE.has(toolName) ? body.split("\n").at(-1)?.trim() : undefined;
  if (last) parts.push(theme.fg("toolOutput", last));
  return oneLine(parts.join(separator));
};

export default function (pi: ExtensionAPI) {
  pi.registerToolRenderer((toolName, next) => {
    const base = next();
    const delegate = base?.renderResult;
    if (!delegate || KEEP_BODY.has(toolName)) return base;
    return {
      ...base,
      renderResult: (result, options, theme, context) =>
        options.expanded || options.isPartial || context.isError || showsImage(result)
          ? delegate(result, options, theme, context)
          : summarize(toolName, result, theme, context),
    };
  });
}
