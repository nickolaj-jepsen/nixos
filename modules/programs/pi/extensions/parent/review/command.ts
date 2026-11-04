/**
 * The `/rv` grammar (D11): `inbox` and `send` are subcommands, a handful of
 * scope names are shortcuts, and everything else is tuicr's own argv — a bare
 * `/rv` is tuicr's default view. There is no picker to keep in step with tuicr:
 * what it documents is what you type.
 *
 * The typed text is split here and never through a shell (B2): an owner's
 * revset reaches tuicr as argv elements, so quotes and spaces are data.
 *
 * A review that starts is refused while the agent is streaming (D5):
 * suspending the TUI mid-turn would stall the model behind a review it cannot
 * see. The subcommands are let through — they queue or notify and never take
 * the terminal.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

export type ParsedReview =
  /** Run tuicr on this argv, split from what the owner typed. */
  | { kind: "open"; args: string[] }
  | { kind: "inbox" }
  | { kind: "send" }
  | { kind: "refused"; why: string };

const SUBCOMMANDS = ["inbox", "send"] as const;
type Subcommand = (typeof SUBCOMMANDS)[number];

const isSubcommand = (word: string): word is Subcommand =>
  (SUBCOMMANDS as readonly string[]).includes(word);

const STREAMING = "review: the agent is still answering";

/**
 * The scopes worth a word: each is the tuicr argv it stands for, and anything
 * typed after it is appended, so `changes -p src/a.ts` is `-w -p src/a.ts`.
 * `branch` and `last` leave the refs to tuicr, which resolves them where it
 * resolves any other revset, and a checkout without `origin/HEAD` gets tuicr's
 * own error.
 */
const SHORTCUTS: Record<string, readonly string[]> = {
  changes: ["-w"],
  all: ["-A"],
  last: ["-r", "HEAD~1..HEAD"],
  branch: ["-r", "origin/HEAD..HEAD", "-w"],
};

/**
 * The owner's text as argv: whitespace separates, single quotes are literal,
 * double quotes and bare text take a backslash escape, and an unclosed quote
 * runs to the end. No shell is involved, so nothing here expands (B2).
 */
export const splitArgv = (text: string): string[] => {
  const argv: string[] = [];
  let current = "";
  let started = false;
  let quote: '"' | "'" | undefined;
  for (let at = 0; at < text.length; at += 1) {
    const char = text[at] ?? "";
    if (quote !== undefined) {
      if (char === quote) {
        quote = undefined;
      } else if (char === "\\" && quote === '"' && at + 1 < text.length) {
        at += 1;
        current += text[at];
      } else {
        current += char;
      }
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      started = true;
      continue;
    }
    if (char === "\\" && at + 1 < text.length) {
      at += 1;
      current += text[at];
      started = true;
      continue;
    }
    if (/\s/.test(char)) {
      if (started) {
        argv.push(current);
        current = "";
        started = false;
      }
      continue;
    }
    current += char;
    started = true;
  }
  if (started) argv.push(current);
  return argv;
};

/**
 * What the owner typed, ready to hand to tuicr: a shortcut word expands, and
 * anything else is the argv as typed. A bare `/rv` is tuicr's default view.
 */
export const parseReview = async (args: string, ctx: ExtensionContext): Promise<ParsedReview> => {
  const argv = splitArgv(args);
  const [word] = argv;
  // A leading subcommand word is the subcommand; anything after it is a mistake
  // the owner can see rather than a tuicr flag.
  if (word !== undefined && isSubcommand(word)) return { kind: word };
  if (!ctx.isIdle()) return { kind: "refused", why: STREAMING };
  const shortcut = word === undefined ? undefined : SHORTCUTS[word];
  return {
    kind: "open",
    args: shortcut === undefined ? argv : [...shortcut, ...argv.slice(1)],
  };
};
