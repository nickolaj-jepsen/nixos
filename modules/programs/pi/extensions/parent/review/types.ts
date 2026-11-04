/**
 * The contracts both harnesses and every review module share: the review
 * entry, the per-repository claim, a pinned scope, an inbox item, the batch
 * text and where the socket and claim file live (HANDOFF C1–C6).
 *
 * Only Node built-ins are imported at runtime, so `node --experimental-strip-types`
 * loads this outside pi and the contract tests run without the extension host.
 */
import { createHash } from "node:crypto";
import { join } from "node:path";

/** The custom entry type a review is recorded under (C1). */
export const REVIEW_ENTRY = "review";

/** What the reviewer picked; `args` is the argv handed to tuicr (C3). */
export type PinnedScope = {
  mode: "worktree" | "commits" | "picker" | "all" | "pr" | "revset";
  args: string[];
  base?: string;
  head?: string;
  /** A PR number, URL or `owner/repo#N`. */
  target?: string;
};

/** A comment tuicr holds, as the inbox and the model see it (C4). */
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

/** How far the reviewer is through the files (C1's `progress`). */
export type ReviewProgress = { reviewedCount: number; fileCount: number };

/** The review, as recorded on the session branch (C1). */
export type ReviewEntry = {
  v: 1;
  /** The main checkout, so a turn of worktrees still points at one repository. */
  root: string;
  cwd: string;
  harness: "pi";
  slug: string | null;
  scope: PinnedScope;
  socket: string;
  items: InboxItem[];
  /** Comment ids already ingested. */
  seen: string[];
  /** Comment ids carried in a batch already submitted. */
  sent: string[];
  progress: ReviewProgress;
  at: string;
};

/** The per-repository "this session owns the review" record (C2). */
export type Claim = {
  v: 1;
  root: string;
  session: string;
  harness: "pi" | "claude";
  pid: number;
  slug: string | null;
  scope: PinnedScope;
  seen: string[];
  at: string;
};

/** 16 hex characters: short enough for a file name, wide enough that two repositories never meet. */
export const reviewKey = (root: string) =>
  createHash("sha256").update(root).digest("hex").slice(0, 16);

/**
 * C1's field names, typed as a complete map: a field added to `ReviewEntry`
 * fails to compile until it is named here. A7 asserts the claim keys the same way.
 */
export const REVIEW_ENTRY_FIELDS = {
  v: true,
  root: true,
  cwd: true,
  harness: true,
  slug: true,
  scope: true,
  socket: true,
  items: true,
  seen: true,
  sent: true,
  progress: true,
  at: true,
} satisfies Record<keyof ReviewEntry, true>;

/** C2's field names, complete in the same way as `REVIEW_ENTRY_FIELDS`. */
export const CLAIM_FIELDS = {
  v: true,
  root: true,
  session: true,
  harness: true,
  pid: true,
  slug: true,
  scope: true,
  seen: true,
  at: true,
} satisfies Record<keyof Claim, true>;

/** `<runtime>/pi-review/<key>.sock`; the review outlives the pi process that started it (C6). */
export const socketPath = (runtimeDir: string, root: string) =>
  join(runtimeDir, "pi-review", `${reviewKey(root)}.sock`);

/** `<agent dir>/review-claims/<key>.json` (C2). */
export const claimPath = (agentDir: string, root: string) =>
  join(agentDir, "review-claims", `${reviewKey(root)}.json`);

/** The argv that puts tuicr in the pinned scope (C6). */
export const tuicrArgv = (scope: PinnedScope): string[] => {
  switch (scope.mode) {
    case "worktree":
      return ["-w"];
    case "all":
      return ["-A"];
    case "picker":
      return [];
    case "pr":
      return scope.target === undefined ? [] : ["pr", scope.target];
    case "commits":
      if (scope.args.length > 0) return [...scope.args];
      if (scope.base !== undefined && scope.head !== undefined)
        return ["-r", `${scope.base}..${scope.head}`, "-w"];
      // The last commit: tuicr takes the oldest commit inside the range as the
      // base, so the parent has to be spelled out or the slug changes identity
      // (notes/tuicr-dtach.md §2).
      return scope.head === undefined ? [] : ["-r", `${scope.head}~1..${scope.head}`];
    case "revset":
      return [...scope.args];
  }
};

/** The line a submitted prompt must carry to have delivered the batch (C5, D4). */
export const batchMarker = (slug: string) => `\`tuicr review comments --session ${slug}\``;

// Any CSI (private and colon forms too), then OSC, DCS, PM and APC strings up to BEL or ST.
const TERMINAL_SEQUENCE = /\x1b\[[0-?]*[ -/]*[@-~]|\x1b[\]P^_][\s\S]*?(?:\x07|\x1b\\)/g;

/**
 * Comment text is read by the model and drawn in the editor that holds the batch,
 * so terminal control goes and everything else stays, newlines included (B1).
 */
export const batchSafe = (text: string) =>
  text.replace(TERMINAL_SEQUENCE, "").replace(/[\x00-\x09\x0b-\x1f\x7f]/g, "");

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
 * The prefilled batch (C5), byte for byte: a header naming the session and the
 * repository, then one numbered line per comment. Comment text is data — it is
 * never escaped into a command, and newlines stay newlines (B1).
 */
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

/** The fields tuicr's `review comments` prints, of which C4 names the ones we keep. */
export type RawComment = {
  id?: unknown;
  path?: unknown;
  start_line?: unknown;
  end_line?: unknown;
  side?: unknown;
  comment_type?: unknown;
  author?: unknown;
  content?: unknown;
  created_at?: unknown;
  /** Printed by tuicr and dropped by C4, like every field C4 does not name. */
  lifecycle_state?: unknown;
};

const text = (value: unknown) => (typeof value === "string" ? value : null);
const line = (value: unknown) =>
  typeof value === "number" && Number.isInteger(value) ? value : null;

/** A comment tuicr printed without an id still needs one that survives reordering. */
const derivedId = (comment: RawComment) =>
  `c-${createHash("sha256")
    .update(
      JSON.stringify([
        comment.path ?? null,
        comment.start_line ?? null,
        comment.end_line ?? null,
        comment.content ?? null,
      ]),
    )
    .digest("hex")
    .slice(0, 16)}`;

/** One `review comments` element as an inbox item (C4); unknown fields are dropped, never trusted. */
export const inboxItem = (comment: RawComment): InboxItem => {
  const side = text(comment.side);
  return {
    id: text(comment.id) ?? derivedId(comment),
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
