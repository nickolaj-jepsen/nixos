/**
 * `/rv`'s logic, as data: D1's scopes, the per-repository review state (C2),
 * the comments tuicr prints (C4) and the batch they become (C5).
 *
 * A mod's `$` may only be called at the call site the validator reads, so the
 * host calls stay in `register.tsx`; everything here is a pure function of what
 * it read, which is also what the test drives it with.
 */
import type { PrAnswer } from "./menus";

export const REVIEW_PANE = "review";
export const REVIEW_TITLE = "Review";

const STATE = "review-state";
const SHORT_SHA = 7;

/** C3: what the reviewer picked; `args` is the argv handed to tuicr. */
export type PinnedScope = {
  mode: "worktree" | "commits" | "picker" | "all" | "pr" | "revset";
  args: string[];
  base?: string;
  head?: string;
  /** A PR number, URL or `owner/repo#N`. */
  target?: string;
};

/** C2: what this checkout's review told this session, so the next send can pick it up. */
export type ReviewState = {
  v: 1;
  root: string;
  slug: string | null;
  seen: string[];
  at: string;
};

/**
 * C2's field names, typed as a complete map: a field added to `ReviewState`
 * fails to compile until it is named here, and the test reads the file back
 * against it.
 */
export const STATE_FIELDS = {
  v: true,
  root: true,
  slug: true,
  seen: true,
  at: true,
} satisfies Record<keyof ReviewState, true>;

/** C4: a comment tuicr holds, as the batch carries it. */
export type InboxItem = {
  id: string;
  path: string | null;
  startLine: number | null;
  endLine: number | null;
  side: "old" | "new" | null;
  type: string | null;
  author: string | null;
  body: string;
  at: string;
};

/** The fields tuicr's `review comments` prints, of which C4 names the ones we keep. */
type RawComment = {
  id?: unknown;
  path?: unknown;
  start_line?: unknown;
  end_line?: unknown;
  side?: unknown;
  comment_type?: unknown;
  author?: unknown;
  content?: unknown;
  created_at?: unknown;
};

/** A row of the picker: D1's scopes, and `"revset"` for the one that has to be typed. */
export type ReviewRow = {
  id: string;
  label: string;
  description?: string;
  unavailable?: string;
  /** What pressing it pins; `"revset"` asks for the revset first. */
  pin?: PinnedScope | "revset";
};

/** The picker as drawn; `rows` is null while git answers. */
export type ReviewMenu = {
  title: string;
  context?: string;
  rows: ReviewRow[] | null;
  error?: string;
  /** The revset row was pressed: the pane asks for one instead of listing rows. */
  typing?: boolean;
};

/** What one round of read-only git and gh said about the checkout. */
export type ReviewFacts = {
  branch: string | null;
  /** The commit at HEAD, full, or "" before the first one. */
  head: string;
  /** HEAD's parent, or "" when HEAD is the root commit. */
  parent: string;
  /** `origin/HEAD`, resolved, or "" when there is none. */
  base: string;
  dirty: boolean;
  pr: PrAnswer;
};

/** D1's rows, each keeping its place and saying in a few words why it cannot run. */
export const reviewMenu = (facts: ReviewFacts): ReviewMenu => {
  const { branch, head, parent, base, dirty, pr } = facts;
  const number = typeof pr === "object" && pr !== null ? pr.number : undefined;
  const noPr =
    pr === "no-gh"
      ? "gh not installed"
      : pr === "unknown"
        ? "gh could not say"
        : "no pull request on this branch";
  const rows: ReviewRow[] = [
    {
      id: "worktree",
      label: "Review uncommitted changes",
      unavailable: dirty ? undefined : "no changes",
      pin: dirty ? { mode: "worktree", args: ["-w"] } : undefined,
    },
    {
      id: "branch",
      label: "Review this branch against origin/HEAD",
      description: branch ?? undefined,
      unavailable: !branch
        ? "detached HEAD"
        : !base
          ? "no origin/HEAD"
          : !head
            ? "no commits yet"
            : undefined,
      pin:
        branch && base && head
          ? { mode: "commits", args: ["-r", `${base}..${head}`, "-w"], base, head }
          : undefined,
    },
    {
      id: "last",
      label: `Review the last commit${head ? ` ${head.slice(0, SHORT_SHA)}` : ""}`,
      unavailable: !head ? "no commits yet" : !parent ? "no earlier commit" : undefined,
      pin:
        head && parent ? { mode: "commits", args: ["-r", `${head}~1..${head}`], head } : undefined,
    },
    { id: "picker", label: "Pick a commit range in tuicr", pin: { mode: "picker", args: [] } },
    { id: "all", label: "Review every tracked file", pin: { mode: "all", args: ["-A"] } },
    {
      id: "pr",
      label: number ? `Review pull request #${number}` : "Review a pull request",
      unavailable: number ? undefined : noPr,
      pin: number
        ? { mode: "pr", args: ["pr", String(number)], target: String(number) }
        : undefined,
    },
    { id: "revset", label: "Review a revset…", pin: "revset" },
  ];
  return { title: REVIEW_TITLE, context: branch ?? undefined, rows };
};

/** D1's custom row: what the person typed, as one argv element and never a shell string (B2). */
export const revsetScope = (answer: string): PinnedScope | undefined => {
  const revset = answer.trim();
  return revset ? { mode: "revset", args: ["-r", revset] } : undefined;
};

/** The state a fresh review writes: no slug yet, nothing delivered (C2). */
export const newState = ({ root, at }: Pick<ReviewState, "root" | "at">): ReviewState => ({
  v: 1,
  root,
  slug: null,
  seen: [],
  at,
});

/** C2's atomic write: a stamp-suffixed temp beside the state, then a rename onto it. */
export const stateFile = (state: ReviewState, path: string, stamp: number) => ({
  temp: `${path}.${stamp}.tmp`,
  text: `${JSON.stringify(state, null, 2)}\n`,
});

/** sha256 of `text` as hex, lower case: what names the state file and an id-less comment. */
const sha256 = async (text: string) => {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
};

/** 16 hex of sha256(root): short enough for a file name, wide enough that two repositories never meet. */
export const reviewKey = async (root: string) => (await sha256(root)).slice(0, 16);

/** `<agent dir>/review-state/<key>.json`, beside pi's own review state (C2). */
export const statePath = async (agentDir: string, root: string) =>
  `${agentDir}/${STATE}/${await reviewKey(root)}.json`;

const text = (value: unknown) => (typeof value === "string" ? value : null);
const line = (value: unknown) =>
  typeof value === "number" && Number.isInteger(value) ? value : null;

/** A comment tuicr printed without an id still needs one that survives reordering. */
const derivedId = async (comment: RawComment) =>
  `c-${(
    await sha256(
      JSON.stringify([
        comment.path ?? null,
        comment.start_line ?? null,
        comment.end_line ?? null,
        comment.content ?? null,
      ]),
    )
  ).slice(0, 16)}`;

/** One `review comments` element as an inbox item (C4); unknown fields are dropped, never trusted. */
const inboxItem = async (comment: RawComment): Promise<InboxItem> => {
  const side = text(comment.side);
  return {
    id: text(comment.id) ?? (await derivedId(comment)),
    path: text(comment.path),
    startLine: line(comment.start_line),
    endLine: line(comment.end_line),
    side: side === "old" || side === "new" ? side : null,
    type: text(comment.comment_type),
    author: text(comment.author),
    body: text(comment.content) ?? "",
    at: text(comment.created_at) ?? "",
  };
};

/** The array `tuicr review comments` prints; anything else is no comments. */
export const parseComments = async (stdout: string): Promise<InboxItem[]> => {
  try {
    const printed = JSON.parse(stdout) as unknown;
    return Array.isArray(printed)
      ? await Promise.all(printed.map((comment) => inboxItem(comment as RawComment)))
      : [];
  } catch {
    return [];
  }
};

/** A session `tuicr review list` prints. */
export type Listed = { slug?: unknown; updated_at?: unknown; active?: unknown };

export const parseList = (stdout: string): Listed[] => {
  try {
    const printed = JSON.parse(stdout) as unknown;
    return Array.isArray(printed) ? (printed as Listed[]) : [];
  } catch {
    return [];
  }
};

/**
 * The review this claim started: the one tuicr opened for this checkout after the
 * claim was written, live now or left behind when its window closed (M2, without
 * a socket). `windowMs` covers tuicr's slow start after the spawn.
 */
export const pickSlug = (listed: readonly Listed[], since: string, windowMs: number) => {
  const floor = Date.parse(since) - windowMs;
  const ours = listed.filter(
    (entry) => typeof entry.slug === "string" && !(Date.parse(String(entry.updated_at)) < floor),
  );
  const newest = ours.reduce<Listed | undefined>(
    (best, entry) =>
      best === undefined ||
      Date.parse(String(entry.updated_at)) > Date.parse(String(best.updated_at))
        ? entry
        : best,
    undefined,
  );
  const pick = ours.find((entry) => entry.active === true) ?? newest;
  return typeof pick?.slug === "string" ? pick.slug : undefined;
};

/** The comments this claim has not drafted yet: unseen, and newer than the claim (C4). */
export const freshItems = (
  items: readonly InboxItem[],
  seen: readonly string[],
  since: string,
): InboxItem[] => {
  const known = new Set(seen);
  const floor = Date.parse(since);
  return items.filter((item) => !known.has(item.id) && !(Date.parse(item.at) <= floor));
};

/** The line a submitted prompt must carry to have delivered the batch (C5, D4). */
export const batchMarker = (slug: string) => `\`tuicr review comments --session ${slug}\``;

const location = (item: InboxItem) => {
  if (item.path === null) return "";
  const { startLine, endLine } = item;
  const lines =
    startLine === null
      ? ""
      : endLine === null || endLine === startLine
        ? `:${startLine}`
        : `:${startLine}-${endLine}`;
  return `\`${batchSafe(item.path)}${lines}\` `;
};

/**
 * C5's prefilled batch, byte for byte: a header naming the session and the
 * repository, then one numbered line per comment. Comment text is data — it is
 * never escaped into a command, and newlines stay newlines (B1).
 */
// Any CSI (private and colon forms too), then OSC, DCS, PM and APC strings up to BEL or ST.
const TERMINAL_SEQUENCE = /\x1b\[[0-?]*[ -/]*[@-~]|\x1b[\]P^_][\s\S]*?(?:\x07|\x1b\\)/g;

/**
 * The same rule as the pi side's `batchSafe`: the batch is read by the model and
 * drawn in the prompt, so terminal control goes and the rest of the bytes stay (B1).
 */
const batchSafe = (text: string) =>
  text.replace(TERMINAL_SEQUENCE, "").replace(/[\x00-\x09\x0b-\x1f\x7f]/g, "");

export const batchText = (slug: string, root: string, items: readonly InboxItem[]) => {
  const header = [
    `Review comments from tuicr (session ${slug}, repo ${root}). Read the full JSON with`,
    `${batchMarker(slug)} (tuicr skill) if you need it.`,
  ].join("\n");
  const lines = items.map((item, index) => {
    const type = item.type === null ? "" : `[${batchSafe(item.type)}] `;
    return `${index + 1}. ${location(item)}${type}${batchSafe(item.body)}`;
  });
  return `${header}\n\n${lines.join("\n")}`;
};

/** The batch above what the person had typed, never over it (the answer mod's placement). */
export const placeReply = (draft: string, batch: string) =>
  draft.trim() ? `${batch}\n\n${draft}` : batch;
