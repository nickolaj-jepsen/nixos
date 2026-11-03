/**
 * What a review looks at: D1's rows, which of them this checkout can offer, and
 * the argv each one pins so a later launch lands in the same tuicr session (D2,
 * C3).
 *
 * Only `readFacts` touches the repository. `rows`, `pinScope` and `pinArgv` are
 * pure, so the answers for a clean tree, a detached HEAD or a missing
 * `origin/HEAD` are asserted without a working copy, and the picker is a thin
 * rendering of the same table the tests check.
 *
 * The pinning is the point: a branch name moves, and a moved HEAD is a new
 * tuicr session (notes/tuicr-dtach.md §2), so a picked row is resolved to commit
 * hashes once and every later launch reuses those hashes.
 */
import { execFile } from "node:child_process";
import { accessSync, constants, realpathSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import {
  type Component,
  Key,
  matchesKey,
  type TUI,
  truncateToWidth,
  visibleWidth,
} from "@earendil-works/pi-tui";
import type { PinnedScope } from "./types.ts";

/** D1's rows, in the order the picker shows them. */
export type ScopeId = "worktree" | "branch" | "lastCommit" | "picker" | "all" | "pr" | "revset";

/** A row of the picker: what it reviews, and why it cannot when it cannot. */
export type ScopeRow = {
  id: ScopeId;
  label: string;
  /** The argv it pins, or what it asks for, shown beside the label. */
  detail: string;
  /** Set when the row cannot be picked here; the picker skips it and says why. */
  unavailable?: string;
  /** The row needs typed text before it pins: a PR target or a revset. */
  asks?: "pr" | "revset";
};

/** What the picker can know about the checkout, read once per open. */
export type ScopeFacts = {
  cwd: string;
  /** The worktree root, or null outside git. */
  root: string | null;
  /** HEAD's commit, null in a repository with no commits. */
  head: string | null;
  /** `origin/HEAD`'s commit, null when the remote or its HEAD is missing. */
  base: string | null;
  /** Staged or unstaged changes to tracked files: what `-w` would show. */
  dirty: boolean;
  /** `HEAD~1` resolves, so the last-commit row has a range to review. */
  parent: boolean;
  /** `gh` is on PATH, so a pull request can be named. */
  gh: boolean;
};

/** A row the owner picked, with the text a row that asks for one collected. */
export type ScopeChoice = { row: ScopeId; text?: string };

/** A pinned scope, or why the choice cannot be pinned here. */
export type ScopePick = { ok: true; scope: PinnedScope } | { ok: false; why: string };

const GIT_TIMEOUT_MS = 5_000;
const MAX_OUTPUT = 1 << 16;

const real = (path: string) => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};

/** git with argv and no shell; undefined for the failures that mean "not there". */
const git = (cwd: string, args: string[]): Promise<string | undefined> =>
  new Promise((resolve) =>
    execFile(
      "git",
      args,
      { cwd, encoding: "utf8", timeout: GIT_TIMEOUT_MS, maxBuffer: MAX_OUTPUT },
      (error, stdout) => resolve(error === null ? stdout.trim() : undefined),
    ),
  );

const onPath = (command: string): boolean =>
  (process.env.PATH ?? "")
    .split(":")
    .filter((dir) => dir !== "")
    .some((dir) => {
      try {
        accessSync(join(dir, command), constants.X_OK);
        return true;
      } catch {
        return false;
      }
    });

/**
 * The checkout as the picker sees it. Five git answers at once, and `gh` from
 * the PATH; every failure reads as absent rather than throwing, because a
 * missing remote or an empty repository is an ordinary state of a checkout.
 */
export const readFacts = async (cwd: string): Promise<ScopeFacts> => {
  const [root, head, base, parent, status] = await Promise.all([
    git(cwd, ["rev-parse", "--path-format=absolute", "--show-toplevel"]),
    git(cwd, ["rev-parse", "--verify", "--quiet", "HEAD"]),
    git(cwd, ["rev-parse", "--verify", "--quiet", "origin/HEAD^{commit}"]),
    git(cwd, ["rev-parse", "--verify", "--quiet", "HEAD~1"]),
    // Untracked files are not in a diff, and `-w` on a tree with nothing staged
    // or unstaged exits 1 (notes/tuicr-dtach.md §2).
    git(cwd, ["status", "--porcelain", "--untracked-files=no"]),
  ]);
  return {
    cwd: real(cwd),
    root: root === undefined || root === "" ? null : real(root),
    head: head === undefined || head === "" ? null : head,
    base: base === undefined || base === "" ? null : base,
    dirty: (status ?? "") !== "",
    parent: parent !== undefined && parent !== "",
    gh: onPath("gh"),
  };
};

/** D1's rows and their per-row availability in this checkout. */
export const rows = (facts: ScopeFacts): ScopeRow[] => {
  const missing = facts.head === null ? "no commits yet" : undefined;
  return [
    {
      id: "worktree",
      label: "uncommitted changes",
      detail: "-w",
      unavailable: facts.dirty ? undefined : "the working tree is clean",
    },
    {
      id: "branch",
      label: "branch vs origin/HEAD",
      detail: "-r <base>..<head> -w",
      unavailable: facts.base === null ? "no origin/HEAD" : missing,
    },
    {
      id: "lastCommit",
      label: "last commit",
      detail: "-r <head>~1..<head>",
      unavailable: missing ?? (facts.parent ? undefined : "no parent commit"),
    },
    { id: "picker", label: "tuicr's commit picker", detail: "tuicr's own ranges" },
    { id: "all", label: "every tracked file", detail: "-A", unavailable: missing },
    {
      id: "pr",
      label: "pull request",
      detail: "pr <number|url>",
      unavailable: facts.gh ? undefined : "gh is not installed",
      asks: "pr",
    },
    { id: "revset", label: "custom revset", detail: "-r <revset>", asks: "revset" },
  ];
};

/**
 * The row's scope with its commits resolved (D2), or why it cannot be pinned.
 * Pure: `facts` is the only thing it knows about the checkout.
 */
export const pinScope = (choice: ScopeChoice, facts: ScopeFacts): ScopePick => {
  const row = rows(facts).find((candidate) => candidate.id === choice.row);
  if (row === undefined) return { ok: false, why: `review: ${choice.row} is not a scope` };
  if (row.unavailable !== undefined) return { ok: false, why: `review: ${row.unavailable}` };
  const text = (choice.text ?? "").trim();
  switch (row.id) {
    case "worktree":
      return { ok: true, scope: { mode: "worktree", args: ["-w"] } };
    case "branch":
      // Both ends resolved, so the session identity survives the branch moving.
      return facts.base === null || facts.head === null
        ? { ok: false, why: "review: no origin/HEAD" }
        : {
            ok: true,
            scope: {
              mode: "commits",
              args: ["-r", `${facts.base}..${facts.head}`, "-w"],
              base: facts.base,
              head: facts.head,
            },
          };
    case "lastCommit": {
      if (facts.head === null) return { ok: false, why: "review: no commits yet" };
      // tuicr takes the oldest commit inside the range as the base, so the
      // parent has to be spelled out or a one-commit review changes identity.
      const range = `${facts.head}~1..${facts.head}`;
      return { ok: true, scope: { mode: "commits", args: ["-r", range], head: facts.head } };
    }
    case "picker":
      return { ok: true, scope: { mode: "picker", args: [] } };
    case "all":
      return { ok: true, scope: { mode: "all", args: ["-A"] } };
    case "pr":
      return text === ""
        ? { ok: false, why: "review: no pull request named" }
        : { ok: true, scope: { mode: "pr", args: ["pr", text], target: text } };
    case "revset": {
      // An owner who typed the flag already still gets one `-r` and one element.
      const revset = text.replace(/^(?:-r|--revisions)\s+/, "");
      return revset === ""
        ? { ok: false, why: "review: no revset given" }
        : { ok: true, scope: { mode: "revset", args: ["-r", revset] } };
    }
  }
};

/**
 * Pass-through `/review <argv>`: the typed argv is the scope, unaltered except
 * for `-p`, which only filters the diff. Identity is what a pinned scope is
 * for, and a filter left in it would hide comments from a later launch, so it
 * is dropped (B2 keeps the rest as argv elements, never a shell string).
 * undefined means the argv was nothing but filters.
 */
export const pinArgv = (argv: readonly string[]): PinnedScope | undefined => {
  const args: string[] = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? "";
    if (arg === "-p" || arg === "--path") {
      index += 1;
      continue;
    }
    if (arg.startsWith("--path=") || (arg.startsWith("-p") && !arg.startsWith("--"))) continue;
    args.push(arg);
  }
  if (args.length === 0) return undefined;
  const only = (flags: string[]) =>
    args.length === flags.length && args.every((a, i) => a === flags[i]);
  if (only(["-w"])) return { mode: "worktree", args };
  if (only(["-A"])) return { mode: "all", args };
  const [first, target] = args;
  if (first === "pr" && target !== undefined) return { mode: "pr", args, target };
  // A revset is the only mode whose argv is taken as typed: `-w -r R` and
  // `--file x` keep their own meaning without being re-derived from fields.
  return { mode: "revset", args };
};

/** Columns of the picker, borders included. */
const PICKER_WIDTH = 64;
const MIN_WIDTH = 24;
const MAX_LABEL = 24;

const pad = (text: string, width: number) =>
  text + " ".repeat(Math.max(0, width - visibleWidth(text)));

/**
 * D1's picker: one row per scope, the unavailable ones dim and skipped by the
 * cursor, and the hint line naming the keys. An overlay, so the transcript
 * underneath stays where it was.
 */
export class ScopePicker implements Component {
  private readonly tui: TUI;
  private readonly theme: Theme;
  private readonly done: (choice: ScopeChoice | undefined) => void;
  private readonly table: ScopeRow[];
  private index: number;
  private closed = false;

  constructor(
    tui: TUI,
    theme: Theme,
    facts: ScopeFacts,
    done: (choice: ScopeChoice | undefined) => void,
  ) {
    this.tui = tui;
    this.theme = theme;
    this.done = done;
    this.table = rows(facts);
    this.index = Math.max(
      0,
      this.table.findIndex((row) => row.unavailable === undefined),
    );
  }

  // Nothing is cached between frames, so a theme change needs no work here.
  invalidate(): void {}

  dispose(): void {}

  handleInput(data: string): void {
    if (matchesKey(data, Key.escape) || matchesKey(data, "ctrl+c")) {
      this.finish(undefined);
      return;
    }
    if (matchesKey(data, Key.enter)) {
      const row = this.table[this.index];
      this.finish(row === undefined ? undefined : { row: row.id });
      return;
    }
    const step =
      matchesKey(data, Key.up) || data === "k"
        ? -1
        : matchesKey(data, Key.down) || data === "j"
          ? 1
          : 0;
    if (step === 0) return;
    for (let at = this.index + step; at >= 0 && at < this.table.length; at += step) {
      if (this.table[at]?.unavailable !== undefined) continue;
      this.index = at;
      this.tui.requestRender();
      return;
    }
  }

  render(width: number): string[] {
    const theme = this.theme;
    const inner = Math.max(MIN_WIDTH, width) - 2;
    const labelWidth = Math.min(
      MAX_LABEL,
      Math.max(...this.table.map((row) => visibleWidth(row.label))),
    );
    const border = (text: string) => theme.fg("borderMuted", text);
    const cell = (text: string) => border("│") + pad(text, inner) + border("│");
    const lines = this.table.map((row, at) => {
      const selected = at === this.index;
      const marker = selected ? theme.fg("accent", " › ") : "   ";
      const label = pad(row.label, labelWidth);
      const named = selected ? theme.fg("accent", theme.bold(label)) : label;
      const aside =
        row.unavailable === undefined
          ? theme.fg("muted", row.detail)
          : theme.fg("dim", `· ${row.unavailable}`);
      return cell(truncateToWidth(`${marker}${named}  ${aside}`, inner, "…", true));
    });
    const title = theme.fg("accent", theme.bold(" Review scope "));
    const hint = theme.fg("dim", " ↑/↓ move · enter review · esc cancel ");
    return [
      border("╭─") +
        title +
        border(`${"─".repeat(Math.max(0, inner - 1 - visibleWidth(" Review scope ")))}╮`),
      ...lines,
      border(`╰${"─".repeat(Math.max(0, inner - 1 - visibleWidth(hint)))}`) + hint + border("╯"),
    ];
  }

  private finish(choice: ScopeChoice | undefined): void {
    if (this.closed) return;
    this.closed = true;
    this.done(choice);
  }
}

/** The picker needs a real terminal; rpc and print modes have no overlay to draw. */
export const canPick = (ctx: ExtensionContext): boolean => ctx.mode === "tui" && ctx.hasUI;

/**
 * D1's picker, then whatever the picked row asks for: a PR target or a revset
 * is typed and pinned as one argv element (B2). undefined means the owner
 * cancelled or the row could not be pinned, and the reason has been notified.
 *
 * This is also the seam another module opens the picker through, so a bare
 * `/review` and an attach path show the same table.
 */
export const chooseScope = async (ctx: ExtensionContext): Promise<PinnedScope | undefined> => {
  const facts = await readFacts(ctx.cwd);
  if (facts.root === null) {
    ctx.ui.notify("review: this folder is not a git checkout", "warning");
    return undefined;
  }
  const choice = await ctx.ui.custom<ScopeChoice | undefined>(
    (tui, theme, _keybindings, done) => new ScopePicker(tui, theme, facts, done),
    {
      overlay: true,
      overlayOptions: { anchor: "center", width: PICKER_WIDTH, margin: 1 },
    },
  );
  if (choice === undefined) return undefined;
  const row = rows(facts).find((candidate) => candidate.id === choice.row);
  let text: string | undefined;
  if (row?.asks === "pr") text = await ctx.ui.input("Pull request (number, URL or owner/repo#N)");
  if (row?.asks === "revset") text = await ctx.ui.input("Revset (for example origin/main..HEAD)");
  if (row?.asks !== undefined && (text ?? "").trim() === "") return undefined;
  const picked = pinScope({ row: choice.row, text }, facts);
  if (!picked.ok) {
    ctx.ui.notify(picked.why, "warning");
    return undefined;
  }
  return picked.scope;
};
