import { atom, read, update } from "claude-code";
import type {
  CommandRunResult,
  EngineInterface,
  ProcessRunResult,
  Register,
  RenderSurface,
} from "claude-code";

import type { FolderApp, Menu, MenuKind, Row } from "../types";
import {
  chooseRemote,
  folderMenu,
  gitMenu,
  parsePr,
  parseStatus,
  type PrAnswer,
  type Status,
} from "./menus";
import { HUB, notesMenu, OPENER, parseNotes } from "./notes";
import {
  batchMarker,
  batchText,
  claimFile,
  claimPath,
  freshItems,
  newClaim,
  ownsClaim,
  parseComments,
  parseList,
  pickSlug,
  placeReply,
  REVIEW_PANE,
  REVIEW_TITLE,
  reviewMenu,
  revsetScope,
  type Claim,
  type PinnedScope,
  type ReviewFacts,
  type ReviewMenu,
  type ReviewRow,
} from "./review";

const PANE = "git-menu";
const TITLES: Record<MenuKind, string> = { git: "Git", folder: "Open folder", notes: "Notes" };
const HINTS = "1-9 or Enter picks · Esc closes";
const GIT_TIMEOUT_MS = 3000;
const GH_TIMEOUT_MS = 5000;
// The first read of a long session's notes takes seconds; a person waits, not a turn.
const NOTES_TIMEOUT_MS = 15_000;
// Starts a GUI app without holding $.process.run, which waits for the output to close.
const DETACH = [
  "sh",
  "-c",
  'exec >/dev/null 2>&1 </dev/null; if command -v setsid >/dev/null; then exec setsid -f "$@"; fi; "$@" &',
  "sh",
];

// `tuicr -w` exits on a clean tree, so that opens its commit picker instead. $0 is tuicr.
const REVIEW = 'if [ -n "$(git status --porcelain)" ]; then exec "$0" -w; fi; exec "$0"';

const menu = atom({ plugin: "git-menu", key: "menu" } as const, null);

let isMacAnswer: Promise<boolean> | undefined;

const run = async (
  $: EngineInterface,
  argv: string[],
  timeoutMs = GIT_TIMEOUT_MS,
): Promise<ProcessRunResult | undefined> => {
  try {
    return await $.process.run(argv, { timeoutMs });
  } catch {
    return undefined;
  }
};

/** One read-only git command; anything it refuses is an empty answer. */
const git = async ($: EngineInterface, cwd: string, args: string[]) => {
  const r = await run($, ["git", "--no-optional-locks", "-C", cwd, ...args]);
  return r?.exitCode === 0 ? r.stdout.trim() : "";
};

const isMac = ($: EngineInterface) =>
  (isMacAnswer ??= run($, ["uname", "-s"]).then((r) => r?.stdout.trim() === "Darwin"));

async function lookupPr($: EngineInterface, cwd: string, status: Status): Promise<PrAnswer> {
  // A branch that was never pushed has no pull request yet, and that is an answer.
  if (!status.branch || !status.upstream) return null;
  let r: ProcessRunResult;
  try {
    r = await $.process.run(["gh", "pr", "view", "--json", "url,number,state,isDraft"], {
      cwd,
      timeoutMs: GH_TIMEOUT_MS,
    });
  } catch {
    return "no-gh";
  }
  if (r.exitCode !== 0) {
    // These two are answers; anything else (offline, auth, timeout) is not.
    return /no pull requests found|no git remotes found/.test(r.stderr) ? null : "unknown";
  }
  return parsePr(r.stdout) ?? "unknown";
}

/** The remote's default branch, then the local main/master refs, then `main`. */
async function defaultBranch($: EngineInterface, cwd: string, remote: string) {
  const head = await git($, cwd, [
    "symbolic-ref",
    "--quiet",
    "--short",
    `refs/remotes/${remote}/HEAD`,
  ]);
  if (head.startsWith(`${remote}/`)) return head.slice(remote.length + 1);
  for (const candidate of ["main", "master"]) {
    const ref = `refs/remotes/${remote}/${candidate}`;
    if (await git($, cwd, ["rev-parse", "--verify", "--quiet", ref])) return candidate;
  }
  return "main";
}

async function buildGit($: EngineInterface, cwd: string): Promise<Menu> {
  const out = await git($, cwd, ["status", "--porcelain=v2", "--branch", "--untracked-files=no"]);
  if (!out) return { kind: "git", title: TITLES.git, rows: [], error: "Not a git repository." };
  const status = parseStatus(out);
  const branch = status.branch;
  const [config, branchRemote, mergeBase, pr] = await Promise.all([
    git($, cwd, ["config", "--get-regexp", "^remote\\..*\\.url$"]),
    branch ? git($, cwd, ["config", "--get", `branch.${branch}.remote`]) : "",
    branch ? git($, cwd, ["config", "--get", `branch.${branch}.gh-merge-base`]) : "",
    lookupPr($, cwd, status),
  ]);
  const remote = chooseRemote(config, branchRemote);
  // Mirrors `gh pr create`: the branch's gh-merge-base, else the remote's default branch.
  const base = mergeBase || (remote ? await defaultBranch($, cwd, remote.name) : "main");
  return gitMenu({ status, remote, base, pr });
}

async function buildFolder($: EngineInterface, cwd: string): Promise<Menu> {
  const mac = await isMac($);
  const launchers: Partial<Record<FolderApp, string[]>> = {};
  if (mac) {
    const bundle = async (app: FolderApp, name: string, args: string[], fresh = false) => {
      if (await $.fs.exists(`/Applications/${name}.app`))
        launchers[app] = fresh
          ? ["open", "-na", `${name}.app`, "--args", ...args]
          : ["open", "-a", name, ...args];
    };
    await Promise.all([
      bundle("code", "Visual Studio Code", [cwd]),
      bundle("smerge", "Sublime Merge", [cwd]),
      // Ghostty takes a directory only as a second instance.
      bundle("ghostty", "Ghostty", [`--working-directory=${cwd}`], true),
    ]);
    launchers.files = ["open", cwd];
  } else {
    const probe = await run($, [
      "sh",
      "-c",
      'for c; do command -v "$c" >/dev/null && echo "$c"; done',
      "sh",
      "code",
      "smerge",
      "nautilus",
      "xdg-open",
      "ghostty",
    ]);
    const found = new Set((probe?.stdout ?? "").split("\n").filter(Boolean));
    if (found.has("code")) launchers.code = ["code", cwd];
    if (found.has("smerge")) launchers.smerge = ["smerge", cwd];
    if (found.has("nautilus")) launchers.files = ["nautilus", cwd];
    else if (found.has("xdg-open")) launchers.files = ["xdg-open", cwd];
    // A fresh shell in the checkout, not this session resumed.
    if (found.has("ghostty")) launchers.ghostty = ["ghostty", `--working-directory=${cwd}`];
  }
  return folderMenu(cwd, launchers, mac);
}

/**
 * Starts tuicr on the checkout in a new Ghostty window and tells the model how
 * to read the comments back, since the review happens outside this session.
 */
async function openDiff($: EngineInterface, cwd: string): Promise<CommandRunResult> {
  if (!(await git($, cwd, ["rev-parse", "--git-dir"]))) return { text: "Not a git repository." };
  const mac = await isMac($);
  const probe = await run($, [
    "sh",
    "-c",
    'for c; do command -v "$c"; done; exit 0',
    "sh",
    "tuicr",
    "ghostty",
  ]);
  const found = (probe?.stdout ?? "").split("\n").filter(Boolean);
  // An absolute path: a mac app started through `open` does not get this PATH.
  const tuicr = found.find((p) => p.endsWith("/tuicr"));
  if (!tuicr) return { text: "tuicr is not installed." };
  const review = [`--working-directory=${cwd}`, "-e", "sh", "-c", REVIEW, tuicr];
  const argv = mac
    ? (await $.fs.exists("/Applications/Ghostty.app"))
      ? ["open", "-na", "Ghostty.app", "--args", ...review]
      : undefined
    : found.some((p) => p.endsWith("/ghostty"))
      ? ["ghostty", ...review]
      : undefined;
  if (!argv) return { text: "Ghostty is not installed." };
  const r = await run($, [...DETACH, ...argv]);
  if (r?.exitCode !== 0) return { text: "Couldn't start Ghostty." };
  return {
    text: "Opened tuicr in a new Ghostty window.",
    context: [
      `I opened tuicr in a separate window to review the changes in ${cwd}. When I say the review is done, find that session with \`tuicr review list --repo ${cwd}\`, read my comments with \`tuicr review comments\` (the tuicr skill) and address them.`,
    ],
  };
}

/** A command by absolute path: on PATH, then the profiles a trimmed PATH may miss, then `also`. */
async function locate($: EngineInterface, name: string, also: string[] = []) {
  const [home, user] = await Promise.all([$.env.get("HOME"), $.env.get("USER")]);
  const probe = await run($, [
    "sh",
    "-c",
    'for c; do command -v "$c" && exit 0; done; exit 1',
    "sh",
    name,
    ...(user ? [`/etc/profiles/per-user/${user}/bin/${name}`] : []),
    `${home ?? ""}/.nix-profile/bin/${name}`,
    ...also,
  ]);
  return probe?.exitCode === 0 ? probe.stdout.trim().split("\n")[0] : undefined;
}

/** Puts this session's notes up in the bar's reader; false where there is no bar. */
async function showInReader($: EngineInterface) {
  const hub = await locate($, HUB);
  if (!hub) return false;
  const r = await run($, [hub, "show", "--session-id", await $.session.id()]);
  return r?.exitCode === 0;
}

async function buildNotes($: EngineInterface): Promise<Menu> {
  const [hub, found, now] = await Promise.all([
    locate($, HUB),
    locate($, OPENER, ["code"]),
    $.clock.now(),
  ]);
  const listed = hub
    ? await run($, [hub, "notes", "--session-id", await $.session.id(), "--json"], NOTES_TIMEOUT_MS)
    : undefined;
  const opener = found && (found.endsWith(`/${OPENER}`) ? [found] : [found, "--reuse-window"]);
  const notes = listed?.exitCode === 0 ? parseNotes(listed.stdout) : undefined;
  return notesMenu({ notes, opener, now });
}

/** tuicr writes its session once it is up; a large diff can take a while, so the window is generous. */
const SLUG_WINDOW_MS = 60_000;

/** The review picker as drawn; it is not persisted, since no pane survives a reload. */
let picker: ReviewMenu | undefined;

const isOpen = async ($: EngineInterface) => (await $.ui.panes()).some((p) => p.id === PANE);

async function close($: EngineInterface) {
  await update($, menu, () => null);
  await $.ui.close({ id: PANE });
}

/** The review's own facts: the branch, the hashes to pin, and what gh says about it. */
async function reviewFacts($: EngineInterface, cwd: string): Promise<ReviewFacts | undefined> {
  const out = await git($, cwd, ["status", "--porcelain=v2", "--branch", "--untracked-files=no"]);
  if (!out) return undefined;
  const status = parseStatus(out);
  const head = /^[0-9a-f]{40}$/i.test(status.oid) ? status.oid : "";
  const [base, parent, pr] = await Promise.all([
    git($, cwd, ["rev-parse", "--verify", "--quiet", "origin/HEAD"]),
    head ? git($, cwd, ["rev-parse", "--verify", "--quiet", `${head}~1`]) : "",
    lookupPr($, cwd, status),
  ]);
  const dirty = out.split("\n").some((row) => row !== "" && !row.startsWith("#"));
  return { branch: status.branch, head, parent, base, dirty, pr };
}

const reviewIsOpen = async ($: EngineInterface) =>
  (await $.ui.panes()).some((pane) => pane.id === REVIEW_PANE);

async function closeReview($: EngineInterface) {
  picker = undefined;
  if (await reviewIsOpen($)) await $.ui.close({ id: REVIEW_PANE });
}

/** `/review`: D1's scopes, the pane up before git answers, as the menus above open. */
async function openReview($: EngineInterface) {
  const cwd = await $.session.cwd();
  picker = { title: REVIEW_TITLE, rows: null };
  if (!(await reviewIsOpen($))) {
    const opened = await $.ui.open({
      id: REVIEW_PANE,
      title: REVIEW_TITLE,
      focus: true,
      closeOnEscape: true,
      rows: 10,
    });
    if (!opened.isPlaced) $.ui.toast(`The review picker can't show yet: ${opened.reason}`);
  }
  const facts = await reviewFacts($, cwd);
  // A close while git answered wins over this one.
  if (!picker) return;
  picker = facts
    ? reviewMenu(facts)
    : { title: REVIEW_TITLE, rows: [], error: "Not a git repository." };
  // The pane reads this module state, not a `$.state` value, so nothing redraws it for us.
  $.ui.invalidate("ui.render");
}

/** openDiff's window, on the argv the scope pinned: tuicr's own args, never a shell string (B2). */
async function reviewWindow($: EngineInterface, cwd: string, args: readonly string[]) {
  const mac = await isMac($);
  const probe = await run($, [
    "sh",
    "-c",
    'for c; do command -v "$c"; done; exit 0',
    "sh",
    "tuicr",
    "ghostty",
  ]);
  const found = (probe?.stdout ?? "").split("\n").filter(Boolean);
  // An absolute path: a mac app started through `open` does not get this PATH.
  const tuicr = found.find((path) => path.endsWith("/tuicr"));
  if (!tuicr) return undefined;
  // `exec "$@"` hands tuicr the argv as argv: a revset with a quote in it stays one element.
  const review = [
    `--working-directory=${cwd}`,
    "-e",
    "sh",
    "-c",
    'exec "$@"',
    "sh",
    tuicr,
    ...args,
  ];
  if (mac)
    return (await $.fs.exists("/Applications/Ghostty.app"))
      ? ["open", "-na", "Ghostty.app", "--args", ...review]
      : undefined;
  const ghostty = found.find((path) => path.endsWith("/ghostty"));
  return ghostty ? [ghostty, ...review] : undefined;
}

/** This Claude process's pid, for C2's staleness rule: there is no Node here, so the shell says it. */
async function reviewPid($: EngineInterface) {
  const said = await run($, ["sh", "-c", "echo $PPID"]);
  const pid = Number((said?.stdout ?? "").trim());
  return Number.isInteger(pid) && pid > 0 ? pid : 0;
}

/** pi's agent directory: where C2's claim lives, so both harnesses write one file. */
async function reviewClaimPath($: EngineInterface, root: string) {
  const [dir, home] = await Promise.all([$.env.get("PI_CODING_AGENT_DIR"), $.env.get("HOME")]);
  return claimPath(dir ?? `${home ?? ""}/.pi/agent`, root);
}

/** C2's shape, checked field by field: the file is read and named in notices, never trusted. */
function asClaim(value: unknown): Claim | undefined {
  const claim = value as Partial<Claim> | null;
  if (typeof claim !== "object" || claim === null) return undefined;
  const ok =
    typeof claim.root === "string" &&
    typeof claim.session === "string" &&
    (claim.harness === "pi" || claim.harness === "claude") &&
    typeof claim.pid === "number" &&
    Number.isFinite(claim.pid) &&
    (claim.slug === null || typeof claim.slug === "string") &&
    Array.isArray(claim.seen) &&
    claim.seen.every((id) => typeof id === "string") &&
    typeof claim.at === "string" &&
    typeof claim.scope === "object" &&
    claim.scope !== null &&
    Array.isArray((claim.scope as { args?: unknown }).args);
  return ok ? (claim as Claim) : undefined;
}

async function readClaim($: EngineInterface, path: string): Promise<Claim | undefined> {
  if (!(await $.fs.exists(path))) return undefined;
  try {
    return asClaim(JSON.parse(await $.fs.read(path)));
  } catch {
    return undefined;
  }
}

/** C2's write: a pid-suffixed temp beside the claim, then a rename, so no reader sees half a file. */
async function writeClaim($: EngineInterface, path: string, claim: Claim) {
  const { temp, text } = claimFile(claim, path);
  await $.fs.write(temp, text);
  const moved = await $.process.run(["mv", temp, path]).catch(() => undefined);
  if (moved?.exitCode !== 0)
    $.ui.log(`review: could not write the claim at ${path}`, { to: "debug" });
}

/** Whether a claim's process still runs: a session that quit leaves a claim to overwrite. */
async function running($: EngineInterface, pid: number): Promise<boolean> {
  const probe = await $.process.run(["kill", "-0", String(pid)]).catch(() => undefined);
  return probe?.exitCode === 0;
}

/** Pins the scope, opens the window and records the claim the next send reads. */
async function launchReview($: EngineInterface, scope: PinnedScope) {
  const [cwd, repo, session] = await Promise.all([
    $.session.cwd(),
    $.session.repo(),
    $.session.id(),
  ]);
  if (!repo) {
    $.ui.toast("Not a git repository.");
    return;
  }
  const path = await reviewClaimPath($, repo.root);
  const existing = await readClaim($, path);
  // The file is one repository's review for both harnesses: a live claim that is
  // not this session's is left to it, the same refusal pi's opener makes (U8).
  if (existing !== undefined && !ownsClaim(existing, session) && (await running($, existing.pid))) {
    $.ui.toast(`This repository's review belongs to another ${existing.harness} session.`);
    return;
  }
  const argv = await reviewWindow($, cwd, scope.args);
  if (!argv) {
    $.ui.toast("tuicr and Ghostty are both needed for a review window.");
    return;
  }
  const started = await run($, [...DETACH, ...argv]);
  if (started?.exitCode !== 0) {
    $.ui.toast("Couldn't start Ghostty.");
    return;
  }
  const claim = newClaim({
    root: repo.root,
    session,
    pid: await reviewPid($),
    scope,
    at: new Date(await $.clock.now()).toISOString(),
  });
  // Read-modify-write: a re-launch by the same session keeps what it delivered.
  const seen = existing !== undefined && ownsClaim(existing, session) ? existing.seen : [];
  await writeClaim($, path, { ...claim, seen });
  $.ui.toast("Opened tuicr in a Ghostty window; its comments land in your next prompt.");
}

/** One row: the revset row asks for one first, the rest pin what they carry. */
async function pressReview($: EngineInterface, row: ReviewRow) {
  if (row.unavailable !== undefined || row.pin === undefined) {
    $.ui.toast(`${row.label}: ${row.unavailable ?? "not available"}`);
    return;
  }
  if (row.pin === "revset") {
    if (picker) picker = { ...picker, rows: [], typing: true };
    $.ui.invalidate("ui.render");
    return;
  }
  await launchReview($, row.pin);
  await closeReview($);
}

/** The revset typed into the picker's field, pinned as one argv element (B2). */
async function pinRevset($: EngineInterface, answer: string) {
  const scope = revsetScope(answer);
  if (!scope) return;
  await launchReview($, scope);
  await closeReview($);
}

/** The review's slug: the session tuicr opened for this checkout after the claim (M2). */
async function reviewSlug($: EngineInterface, root: string, since: string) {
  const tuicr = await locate($, "tuicr");
  if (!tuicr) return undefined;
  const listed = await run($, [tuicr, "review", "list", "--repo", root]);
  if (listed?.exitCode !== 0) return undefined;
  return pickSlug(parseList(listed.stdout), since, SLUG_WINDOW_MS);
}

async function reviewComments($: EngineInterface, root: string, slug: string) {
  const tuicr = await locate($, "tuicr");
  if (!tuicr) return undefined;
  const printed = await run($, [tuicr, "review", "comments", "--session", slug, "--repo", root]);
  return printed?.exitCode === 0 ? parseComments(printed.stdout) : undefined;
}

/**
 * After a send: the review's comments become one batch in the prompt box, and the
 * send that carried a batch empties the claim's inbox (U2, D4, D9). Nothing is
 * attached to the prompt unseen and nothing is sent for the person.
 */
async function afterReviewSubmit($: EngineInterface, sent: string) {
  const repo = await $.session.repo();
  if (!repo) return;
  const path = await reviewClaimPath($, repo.root);
  const claim = await readClaim($, path);
  if (!claim || !ownsClaim(claim, await $.session.id())) return;
  const now = new Date(await $.clock.now()).toISOString();
  const slug = claim.slug ?? (await reviewSlug($, claim.root, claim.at));
  if (slug === undefined) return;
  if (sent.includes(batchMarker(slug))) {
    // The batch reached the model: the inbox is empty, and nothing from before the
    // draft is drafted again. `at` stays at the draft's time, not this send's, so a
    // comment made while the batch sat in the prompt still arrives next time.
    await writeClaim($, path, { ...claim, slug, seen: [] });
    return;
  }
  const found = await reviewComments($, claim.root, slug);
  if (!found) return;
  const fresh = freshItems(found, claim.seen, claim.at);
  if (fresh.length === 0) {
    // The slug is worth keeping: the next send reads the comments without asking tuicr first.
    if (claim.slug !== slug) await writeClaim($, path, { ...claim, slug });
    return;
  }
  const box = await $.prompt.read();
  const filled = await $.prompt.fill({
    text: placeReply(box.text, batchText(slug, claim.root, fresh)),
    mode: "replace",
  });
  if (!filled.isFilled) {
    // The ids stay unseen, so the next send drafts them again.
    $.ui.toast("The review batch couldn't go in the prompt: a dialog is open.");
    return;
  }
  await writeClaim($, path, {
    ...claim,
    slug,
    seen: [...claim.seen, ...fresh.map((item) => item.id)],
    at: now,
  });
}

/**
 * Opens a menu, or closes it when it is already up, as a second click on pi's
 * footer did. The pane opens before git answers: one opened after the command
 * hook returned counts as unasked and stays hidden on narrower terminals.
 */
async function show($: EngineInterface, kind: MenuKind) {
  if ((await read($, menu))?.kind === kind && (await isOpen($))) return close($);
  const cwd = await $.session.cwd();
  const title = TITLES[kind];
  await update($, menu, () => ({ kind, title, rows: null }));
  const opened = await $.ui.open({ id: PANE, title, focus: true, closeOnEscape: true, rows: 10 });
  if (!opened.isPlaced) $.ui.toast(`The ${title} menu can't show yet: ${opened.reason}`);
  const built =
    kind === "git"
      ? await buildGit($, cwd)
      : kind === "folder"
        ? await buildFolder($, cwd)
        : await buildNotes($);
  // A close or another menu while git answered wins over this one.
  await update($, menu, (m) => (m?.kind === kind && m.rows === null ? built : m));
  const shown = await read($, menu);
  if (shown?.kind === kind && shown.rows !== null && built.preferred)
    // Cosmetic: a ring that cannot move leaves Tab and the hotkeys working.
    await $.ui.focus({ requestId: PANE, key: built.preferred }).catch(() => undefined);
}

async function press($: EngineInterface, row: Row, surface: RenderSurface) {
  if (!row.action) {
    $.ui.toast(`${row.label}: ${row.unavailable ?? "not available"}`);
    return;
  }
  const action = row.action;
  if (action.kind === "menu") {
    if (action.menu === "notes" && (await showInReader($))) return close($);
    return show($, action.menu);
  }
  if (action.kind === "copy") {
    const r = await $.ui.copy({ text: action.text, surface });
    $.ui.toast(r.isCopied ? `Copied the ${action.what}` : `Couldn't copy: ${r.reason}`);
  } else {
    const argv =
      action.kind === "url" ? [(await isMac($)) ? "open" : "xdg-open", action.url] : action.argv;
    const r = await run($, [...DETACH, ...argv]);
    if (r?.exitCode !== 0) $.ui.toast(`Couldn't start ${argv[0]}`);
  }
  await close($);
}

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    for (const [name, description, argumentHint] of [
      ["git", "Open the git menu: the repository, branch and pull request on the forge", undefined],
      [
        "open",
        "Open the folder menu: this checkout in an editor, file manager or terminal; `plan` reads this session's notes, `diff` reviews the changes in tuicr",
        "[plan|diff]",
      ],
      [
        "review",
        "Review the changes in tuicr, in a Ghostty window; its comments are drafted into the next prompt",
        undefined,
      ],
    ] as const) {
      await $.command
        .register({ name, description, argumentHint, immediate: true })
        .catch((error) =>
          $.ui.log(`git-menu: /${name} not registered: ${String(error)}`, { to: "debug" }),
        );
    }
    return next(e);
  });

  on("command.run", { command: "git" }, async ($) => {
    await show($, "git");
    return { text: "Opened the git menu." };
  });

  on("command.run", { command: "open" }, async ($, e) => {
    if (e.args.trim() === "diff") return openDiff($, await $.session.cwd());
    if (e.args.trim() === "plan") {
      if (await showInReader($)) return { text: "Opened this session's notes in the reader." };
      await show($, "notes");
      return { text: "Opened this session's notes." };
    }
    await show($, "folder");
    return { text: "Opened the folder menu." };
  });

  on("command.run", { command: "review" }, async ($) => {
    await openReview($);
    return { text: "Opened the review picker." };
  });

  // The comments come back on the person's next send, as one batch in the prompt
  // box: nothing is sent for them, and nothing is attached to the prompt unseen.
  on("prompt.submit", async ($, e, next) => {
    const result = await next(e);
    await afterReviewSubmit($, e.text).catch((error) =>
      $.ui.log(`review: ${String(error)}`, { to: "debug" }),
    );
    return result;
  }).catch((_$, e, next) => (next.called ? undefined : next(e)));

  on("ui.close", { id: PANE }, async ($, e, next) => {
    await update($, menu, () => null);
    return next(e);
  });

  on("ui.close", { id: REVIEW_PANE }, async ($, e, next) => {
    // The pane is going; only the rows it drew are left to forget.
    picker = undefined;
    return next(e);
  });

  on("ui.render", { component: "Pane", requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e);
    const m = await read($, menu);
    if (!m) return <Text dimColor>No menu open.</Text>;
    const rows = m.rows ?? [];
    // Notes share one column, so the rows read as a table.
    const width = Math.max(0, ...rows.map((r) => r.label.length));
    return (
      <Box flexDirection="column">
        <Box flexDirection="row">
          <Text bold>{m.title}</Text>
          {m.context ? <Text dimColor>{`  ${m.context}`}</Text> : null}
        </Box>
        {m.error ? (
          <Text dimColor>{m.error}</Text>
        ) : m.rows === null ? (
          <Text dimColor>{m.kind === "notes" ? "Looking for notes…" : "Asking git…"}</Text>
        ) : (
          rows.map((row, i) => {
            const note = row.unavailable ?? row.description;
            return (
              <Button
                key={row.id}
                plain
                hotkey={i < 9 ? String(i + 1) : undefined}
                dimColor={row.action === undefined}
                onPress={(p) => void press($, row, p.surface)}
              >
                {row.label.padEnd(width)}
                {note ? <Text dimColor>{`  ${note}`}</Text> : null}
              </Button>
            );
          })
        )}
        <Text dimColor>{HINTS}</Text>
      </Box>
    );
  });

  on("ui.render", { component: "Pane", requestId: REVIEW_PANE }, async ($, e) => {
    const elements = $.ui.resolve(e);
    const { Box, Text, Button } = elements;
    // Only the terminal, the desktop and the editor take a field; a phone shows the rows alone.
    const Input = "Input" in elements ? elements.Input : undefined;
    const shown = picker;
    if (!shown) return <Text dimColor>No review open.</Text>;
    const rows = shown.rows ?? [];
    // Labels share one column, so the reasons read as a column too.
    const width = Math.max(0, ...rows.map((r) => r.label.length));
    return (
      <Box flexDirection="column">
        <Box flexDirection="row">
          <Text bold>{shown.title}</Text>
          {shown.context ? <Text dimColor>{`  ${shown.context}`}</Text> : null}
        </Box>
        {shown.typing && Input !== undefined ? (
          <Input
            key="revset"
            label="Revset"
            autoFocus
            onSubmit={(text: string) => void pinRevset($, text)}
          />
        ) : shown.error ? (
          <Text dimColor>{shown.error}</Text>
        ) : shown.rows === null ? (
          <Text dimColor>Asking git…</Text>
        ) : (
          rows.map((row, i) => {
            const note = row.unavailable ?? row.description;
            return (
              <Button
                key={row.id}
                plain
                hotkey={i < 9 ? String(i + 1) : undefined}
                dimColor={row.unavailable !== undefined}
                onPress={() => void pressReview($, row)}
              >
                {row.label.padEnd(width)}
                {note ? <Text dimColor>{`  ${note}`}</Text> : null}
              </Button>
            );
          })
        )}
        <Text dimColor>{shown.typing ? "Enter pins the revset · Esc closes" : HINTS}</Text>
      </Box>
    );
  });
};
