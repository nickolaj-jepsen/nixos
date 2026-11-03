/**
 * The `/review` grammar (D11): a bare `/review` resumes a live review or picks a
 * scope, `inbox`, `send`, `take` and `kill` are subcommands, and any other
 * argument is handed to tuicr as argv.
 *
 * The typed scope text is split here and never through a shell (B2): an owner's
 * revset reaches tuicr as argv elements, so quotes and spaces are data.
 *
 * A review that starts or attaches is refused while the agent is streaming
 * (D5): suspending the TUI mid-turn would stall the model behind a review it
 * cannot see. The subcommands are let through — they queue, notify or kill and
 * never take the terminal.
 */
import { existsSync } from "node:fs";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { gitRoots } from "../../shared/git.ts";
import { canPick, chooseScope, pinArgv } from "./scope.ts";
import { type PinnedScope, socketPath } from "./types.ts";

export type ParsedReview =
  /** Open the pinned scope, attach the live review when there is no scope, or pick one. */
  | { kind: "open"; scope: PinnedScope | undefined }
  | { kind: "inbox" }
  | { kind: "send" }
  | { kind: "take" }
  | { kind: "kill" }
  /** Nothing to do: the owner cancelled, and dispatch must stay silent. */
  | { kind: "none" }
  | { kind: "refused"; why: string };

const SUBCOMMANDS = ["inbox", "send", "take", "kill"] as const;
type Subcommand = (typeof SUBCOMMANDS)[number];

const isSubcommand = (word: string): word is Subcommand =>
  (SUBCOMMANDS as readonly string[]).includes(word);

const STREAMING = "review: the agent is still answering";

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
 * A review is live while its socket exists: C6's path, the same rule A2's
 * `alive()` implements. Reading it here is what lets a bare `/review` resume
 * without a picker (D11) while A2 owns creating and removing the socket.
 */
const reviewLive = (cwd: string): boolean => {
  const runtime = process.env.XDG_RUNTIME_DIR;
  if (runtime === undefined || runtime === "") return false;
  const { root, main } = gitRoots(cwd);
  return existsSync(socketPath(runtime, main ?? root ?? cwd));
};

/**
 * Bare `/review`: refuse while streaming, resume what is live, and otherwise
 * ask which scope to review. Without a terminal there is no picker, so tuicr's
 * own default view opens instead of nothing at all.
 */
const bare = async (ctx: ExtensionContext): Promise<ParsedReview> => {
  if (!ctx.isIdle()) return { kind: "refused", why: STREAMING };
  if (reviewLive(ctx.cwd)) return { kind: "open", scope: undefined };
  if (!canPick(ctx)) {
    ctx.ui.notify("review: no scope picker without the terminal UI", "info");
    return { kind: "open", scope: undefined };
  }
  const scope = await chooseScope(ctx);
  return scope === undefined ? { kind: "none" } : { kind: "open", scope };
};

export const parseReview = async (args: string, ctx: ExtensionContext): Promise<ParsedReview> => {
  const argv = splitArgv(args);
  const [word] = argv;
  if (word === undefined) return bare(ctx);
  // A leading subcommand word is the subcommand; anything after it is a mistake
  // the owner can see rather than a tuicr flag.
  if (isSubcommand(word)) return { kind: word };
  if (!ctx.isIdle()) return { kind: "refused", why: STREAMING };
  const scope = pinArgv(argv);
  if (scope === undefined)
    return { kind: "refused", why: "review: -p only filters the diff; name a scope too" };
  return { kind: "open", scope };
};
