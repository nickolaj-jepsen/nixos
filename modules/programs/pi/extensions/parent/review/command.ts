/**
 * The `/review` grammar (D11): bare `/review` opens or resumes a review,
 * `inbox`, `send`, `take` and `kill` are subcommands, and any other argument is
 * passed to tuicr verbatim as argv.
 *
 * A1 owns this file: the picker (D1), the pinned scope (D2), the streaming
 * refusal (D5) and the pass-through argv (D11). This stub only tells the
 * subcommands apart so G0's wiring can be exercised.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { PinnedScope } from "./types.ts";

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

export const parseReview = async (args: string, ctx: ExtensionContext): Promise<ParsedReview> => {
  const [word] = args.trim().split(/\s+/).filter(Boolean);
  if (word === undefined) return { kind: "open", scope: undefined };
  if (isSubcommand(word)) return { kind: word };
  // Pass-through argv and the picker are A1's; until then this is a bare review.
  return { kind: "open", scope: undefined };
};
