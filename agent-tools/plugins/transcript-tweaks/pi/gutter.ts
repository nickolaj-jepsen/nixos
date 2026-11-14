/**
 * Marks the start of every assistant reply with a rule in front of its first
 * line, so a one-sentence answer reads as an answer instead of blending into the
 * tool rows around it.
 *
 * Inline and space-joined rather than a line of its own: a marker alone on a row
 * reads as debris, and it lands next to the collapsed `Thinking...` line of the
 * turn before. Being in front of the text makes it a bullet for the reply.
 *
 * Colouring it is not possible from here. A code span, or a raw ANSI prefix,
 * both bleed their colour across the rest of the rendered line, so the marker
 * takes the message's own colour and earns its weight from the glyph instead.
 *
 * Nothing is added to a reply with no text, which is what a turn that only calls
 * tools produces. The session keeps the untransformed text, so /copy, /export
 * and the model never see the rule.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Left half block: one column wide in Hack Nerd Font, and the heaviest ink that
// still reads as a rule rather than a bullet.
const GUTTER = "▌";

export default function (pi: ExtensionAPI) {
  pi.registerMarkdownTransformer((markdown, context) => {
    if (context.messageType !== "assistant" || markdown.trim() === "") return markdown;
    return `${GUTTER} ${markdown}`;
  });
}
