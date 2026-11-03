/**
 * The `/review` grammar (D11): bare `/review` opens or resumes a review,
 * `inbox`, `send`, `take` and `kill` are subcommands, and any other argument is
 * passed to tuicr verbatim as argv.
 *
 * The grammar shape is frozen at G0; resolving a scope, refusing while the
 * agent streams and pinning hashes belong to the picker (A1).
 */
import type { PinnedScope } from "./types.ts";

export type ParsedReview =
  | { kind: "open"; scope: PinnedScope | undefined }
  | { kind: "inbox" }
  | { kind: "send" }
  | { kind: "take" }
  | { kind: "kill" }
  | { kind: "refused"; why: string };

const SUBCOMMANDS = ["inbox", "send", "take", "kill"] as const;
type Subcommand = (typeof SUBCOMMANDS)[number];

const isSubcommand = (word: string): word is Subcommand =>
  (SUBCOMMANDS as readonly string[]).includes(word);

export const parseReview = async (args: string): Promise<ParsedReview> => {
  const [word] = args.trim().split(/\s+/).filter(Boolean);
  if (word === undefined) return { kind: "open", scope: undefined };
  if (isSubcommand(word)) return { kind: word };
  // Pass-through argv and the picker are A1's; until then this is a bare review.
  return { kind: "open", scope: undefined };
};
