/**
 * `/review` over a fixture checkout: D1's scopes as rows, the argv each one hands
 * tuicr, the claim both harnesses read (C2), and the batch the next send drafts
 * (C5). The engine here is a fake: git, gh, tuicr and the prompt box answer from
 * memory, so no process, no review store and no window is touched.
 */
import type { On } from "claude-code";
import { expect, mock, test } from "claude-code/testing";
import type { Engine, MockClock } from "claude-code/testing";

const PANE = {
  plugin: "git-menu",
  component: "Pane",
  requestId: "review",
  props: {
    title: "Review",
    isFocused: true,
    bodyColumns: 60,
    placement: "inline",
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const;

const RUN = {
  origin: { kind: "composer" },
  presentation: { isFullscreen: true, columns: 160 },
  args: "",
} as const;

const ROOT = "/repo";
const AGENT = "/agent";
const HOME = "/home/me";
const SESSION = "11111111-2222-3333-4444-555555555555";
const NOW = Date.UTC(2026, 9, 31, 12);
const MINUTE = 60_000;
const PID = 4242;
const TUICR = "/run/current-system/sw/bin/tuicr";
const GHOSTTY = "/run/current-system/sw/bin/ghostty";
const BASE = "a".repeat(40);
const HEAD = "b".repeat(40);
const PARENT = "c".repeat(40);
const SHORT = HEAD.slice(0, 7);
const SLUG = `repo@main/staged-and-unstaged/${SHORT}`;
/** sha256("/repo")'s first 16 hex, which is how C2 names the file. */
const CLAIM = `${AGENT}/review-claims/816fc349d3faebf8.json`;
const PR =
  '{"url":"https://github.com/me/repo/pull/12","number":12,"state":"OPEN","isDraft":false}';

/** C2's field names, hand-written: the file pi and Claude share carries exactly these. */
const C2 = ["at", "harness", "pid", "root", "scope", "seen", "session", "slug", "v"];

/** C5's batch for the two comments below, spelled out. */
const BATCH = [
  `Review comments from tuicr (session ${SLUG}, repo ${ROOT}). Read the full JSON with`,
  `\`tuicr review comments --session ${SLUG}\` (tuicr skill) if you need it.`,
  "",
  "1. `src/a.ts:42` [issue] guard the empty token",
  "2. `src/a.ts:88-92` [nit] rename this",
].join("\n");

const COMMENT = {
  id: "c1",
  path: "src/a.ts",
  start_line: 42,
  end_line: 42,
  side: "new",
  comment_type: "issue",
  author: "Nickolaj",
  lifecycle_state: "local_draft",
  // Written nine seconds after the review window opened, as the person types it.
  created_at: "2026-10-31T12:00:09.000000000+00:00",
  content: "guard the empty token",
};

const COMMENTS = [
  COMMENT,
  {
    ...COMMENT,
    id: "c2",
    start_line: 88,
    end_line: 92,
    comment_type: "nit",
    content: "rename this",
  },
];

const ok = (stdout: string, exitCode = 0, stderr = "") => ({
  value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false },
});

type World = {
  /** Every argv the mod started a window with, the detach wrapper stripped. */
  launched: string[][];
  /** The files the mod wrote, by path. */
  files: Map<string, string>;
  /** Every write and every rename, in order: C2's temp-then-rename leaves both. */
  written: string[];
  moved: string[][];
  /** The prompt box as it stands, and every fill that reached it. */
  box: string;
  fills: string[];
  /** Every notice the mod put up, in order. */
  toasts: string[];
  /** What `tuicr review list` says about this checkout's sessions. */
  sessions: unknown[];
  /** What `tuicr review comments` returns for the review. */
  comments: unknown[];
  clock: MockClock;
};

/**
 * Stands in for the host: a fixture checkout with a dirty tree, a branch with a
 * pull request, and tuicr's two review commands.
 */
function world(
  on: On,
  { clean = false, sessions = [] as unknown[], claim = undefined as string | undefined } = {},
): World {
  const w: World = {
    launched: [],
    files: new Map(),
    written: [],
    moved: [],
    box: "",
    fills: [],
    toasts: [],
    sessions,
    clock: mock.clock(on, { now: NOW }),
  };
  if (claim !== undefined) w.files.set(CLAIM, claim);
  w.comments = COMMENTS;
  on("env.get", (_, e) => ({
    value: ({ HOME, USER: "me", PI_CODING_AGENT_DIR: AGENT } as Record<string, string>)[e.name],
  }));
  on("session.id", () => ({ value: SESSION }));
  on("session.cwd", () => ({ value: ROOT }));
  on("session.repo", () => ({ value: { root: ROOT, remote: null, internal: false, name: null } }));
  on("ui.open", () => ({ value: { isPlaced: true } }));
  on("ui.close", () => ({ value: undefined }));
  on("ui.panes", () => ({ value: [] }));
  on("ui.toast", (_, e) => {
    w.toasts.push(e.text ?? "");
    return { value: undefined };
  });
  on("ui.log", () => ({ value: undefined }));
  on("prompt.read", () => ({ value: { text: w.box, cursor: w.box.length } }));
  on("prompt.fill", (_, e) => {
    w.fills.push(e.text);
    w.box = e.text;
    return { isFilled: true };
  });
  on("prompt.submit", (_, e) => ({ text: e.text }));
  on("fs.exists", (_, e) => ({ value: w.files.has(e.path) }));
  on("fs.read", (_, e) => {
    const text = w.files.get(e.path);
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`);
    return { value: text };
  });
  on("fs.write", (_, e) => {
    w.written.push(e.path);
    w.files.set(e.path, e.text);
    return { value: undefined };
  });
  on("process.run", (_, e) => {
    const argv = [...e.argv];
    const line = argv.join(" ");
    if (argv[0] === "uname") return ok("Linux\n");
    if (argv[0] === "mv") {
      w.moved.push([String(argv[1]), String(argv[2])]);
      w.files.set(String(argv[2]), w.files.get(String(argv[1])) ?? "");
      return ok("");
    }
    // This process's pid, as the shell sees it.
    if (argv[0] === "sh" && argv[2] === "echo $PPID") return ok(`${PID}\n`);
    // The detach wrapper: what it starts is the window.
    if (argv[0] === "sh" && String(argv[2]).startsWith("exec >/dev/null")) {
      w.launched.push(argv.slice(4));
      return ok("");
    }
    // `command -v`: openDiff's probe prints both paths, `locate` answers one name.
    if (argv[0] === "sh" && String(argv[2]).startsWith("for c; do command -v")) {
      if (argv.includes("tuicr") && argv.includes("ghostty")) return ok(`${TUICR}\n${GHOSTTY}\n`);
      const found = argv.slice(4).find((c) => c === "tuicr" || c === "ghostty");
      if (found === undefined) return ok("", 1);
      return ok(`${found === "tuicr" ? TUICR : GHOSTTY}\n`);
    }
    // `kill -0`: the claim's process answers while it runs.
    if (argv[0] === "kill" && argv[1] === "-0") return argv[2] === String(PID) ? ok("") : ok("", 1);
    if (argv[0] === "gh") return ok(PR);
    if (argv[0] === "git") {
      if (line.includes(" status ")) {
        return ok(
          `# branch.oid ${HEAD}\n# branch.head feat/x\n# branch.upstream origin/feat/x\n` +
            (clean ? "" : "1 .M N... 100644 100644 100644 1111111 2222222 src/a.ts\n"),
        );
      }
      if (line.endsWith("rev-parse --verify --quiet origin/HEAD")) return ok(`${BASE}\n`);
      if (line.endsWith(`rev-parse --verify --quiet ${HEAD}~1`)) return ok(`${PARENT}\n`);
      return ok("", 1);
    }
    if (argv[0] === TUICR && argv[1] === "review" && argv[2] === "list")
      return ok(JSON.stringify(w.sessions));
    if (argv[0] === TUICR && argv[1] === "review" && argv[2] === "comments")
      return ok(JSON.stringify(w.comments));
    return ok("", 1);
  });
  return w;
}

async function start($: Engine, on: On) {
  on("command.register", (_, e) => ({ value: { command: e.name } }));
  on("session.start", (_, e) => ({ cwd: e.cwd }));
  await $.session.start({ cwd: ROOT, surface: "terminal", isInteractive: true });
}

const openPicker = ($: Engine) => $.command.run({ ...RUN, command: "review" });

/** Presses one row of the open picker. */
async function pressRow($: Engine, key: string) {
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key });
  await pane.unmount();
}

/** `/review`, then the uncommitted-changes row: a review with a claim behind it. */
async function review($: Engine) {
  await openPicker($);
  await pressRow($, "worktree");
}

const send = ($: Engine, text: string) =>
  $.prompt.submit({ text, wait: false, origin: { kind: "composer" } });

const claimOf = (w: World) => JSON.parse(w.files.get(CLAIM) ?? "null") as Record<string, unknown>;

/** A review tuicr opened three seconds after the claim was written, still live. */
const SESSIONS = [{ slug: SLUG, updated_at: "2026-10-31T12:00:03+00:00", active: true }];

test("/review offers D1's scopes in one order", async ($, on) => {
  world(on);
  await start($, on);
  await openPicker($);
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  const keys = (await pane.findAll({ type: "Button" })).map((b) => b.key);
  await pane.unmount();
  expect(keys).toEqual(["worktree", "branch", "last", "picker", "all", "pr", "revset"]);
});

test("a clean tree says so on the row and starts nothing", async ($, on) => {
  const w = world(on, { clean: true });
  await start($, on);
  await openPicker($);
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  const rows = await pane.findAll({ type: "Button" });
  const worktree = rows.find((row) => row.key === "worktree");
  await pane.press({ key: "worktree" });
  await pane.unmount();
  expect(worktree?.text).toContain("no changes");
  expect(w.launched).toEqual([]);
  expect(w.files.has(CLAIM)).toBe(false);
});

test("each scope reaches tuicr as the argv it pinned", async ($, on) => {
  const w = world(on);
  await start($, on);
  const cases: [string, string[]][] = [
    ["worktree", ["-w"]],
    ["branch", ["-r", `${BASE}..${HEAD}`, "-w"]],
    ["last", ["-r", `${HEAD}~1..${HEAD}`]],
    ["picker", []],
    ["all", ["-A"]],
    ["pr", ["pr", "12"]],
  ];
  for (const [key, args] of cases) {
    w.launched = [];
    await openPicker($);
    await pressRow($, key);
    expect(w.launched.at(-1)?.slice(-(args.length + 1))).toEqual([TUICR, ...args]);
  }
});

test("the revset row asks for one and hands it to tuicr as a single argument", async ($, on) => {
  const w = world(on);
  await start($, on);
  await openPicker($);
  await pressRow($, "revset");
  expect(w.launched).toEqual([]);

  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.input({ key: "revset", text: "origin/HEAD..HEAD 'quoted'" });
  await pane.unmount();
  expect(w.launched.at(-1)?.slice(-3)).toEqual([TUICR, "-r", "origin/HEAD..HEAD 'quoted'"]);
});

test("the window opens on the checkout and the claim carries exactly C2's keys", async ($, on) => {
  const w = world(on);
  await start($, on);
  await review($);

  expect(w.launched).toHaveLength(1);
  const [argv = []] = w.launched;
  expect(argv.slice(0, 2)).toEqual([GHOSTTY, `--working-directory=${ROOT}`]);
  expect(argv.slice(0, 5)).toEqual([GHOSTTY, `--working-directory=${ROOT}`, "-e", "sh", "-c"]);
  expect(argv.at(-1)).toBe("-w");
  expect(argv.at(-2)).toBe(TUICR);

  // C2's atomic write: a pid-suffixed temp, then a rename onto the claim.
  const temp = `${CLAIM}.${PID}.tmp`;
  expect(w.written.at(-1)).toBe(temp);
  expect(w.moved.at(-1)).toEqual([temp, CLAIM]);

  const claim = claimOf(w);
  expect(Object.keys(claim).sort()).toEqual(C2);
  expect(claim).toEqual({
    v: 1,
    root: ROOT,
    session: SESSION,
    harness: "claude",
    pid: PID,
    slug: null,
    scope: { mode: "worktree", args: ["-w"] },
    seen: [],
    at: new Date(NOW).toISOString(),
  });
});

test("the next send drafts C5's batch above the draft and marks the comments seen", async ($, on) => {
  const w = world(on, { sessions: SESSIONS });
  await start($, on);
  await review($);
  await w.clock.advance(MINUTE);
  w.box = "my own draft";
  await send($, "carry on");

  expect(w.fills).toEqual([`${BATCH}\n\nmy own draft`]);
  expect(claimOf(w)).toMatchObject({ slug: SLUG, seen: ["c1", "c2"] });
});

test("a send carrying the batch's marker clears the seen ids, and nothing is drafted twice", async ($, on) => {
  const w = world(on, { sessions: SESSIONS });
  await start($, on);
  await review($);
  await w.clock.advance(MINUTE);
  await send($, "carry on");
  expect(w.fills).toHaveLength(1);

  await w.clock.advance(MINUTE);
  await send($, w.box);
  expect(claimOf(w)).toMatchObject({ slug: SLUG, seen: [] });

  // The comments are older than the batch that carried them, so they stay delivered.
  w.fills = [];
  await w.clock.advance(MINUTE);
  await send($, "something else");
  expect(w.fills).toEqual([]);
});

test("a live claim another session holds refuses the review before a window opens", async ($, on) => {
  const held = JSON.stringify({
    v: 1,
    root: ROOT,
    session: "another-session",
    harness: "pi",
    pid: PID,
    slug: SLUG,
    scope: { mode: "worktree", args: ["-w"] },
    seen: [],
    at: new Date(NOW - MINUTE).toISOString(),
  });
  const w = world(on, { claim: held });
  await start($, on);
  await review($);
  expect(w.launched).toEqual([]);
  expect(w.toasts).toContain("This repository's review belongs to another pi session.");
  expect(w.files.get(CLAIM)).toBe(held);
});

test("a comment made while the batch waited in the prompt still arrives next time", async ($, on) => {
  const w = world(on, { sessions: SESSIONS });
  await start($, on);
  await review($);
  await w.clock.advance(MINUTE);
  await send($, "carry on");
  expect(w.fills).toHaveLength(1);

  // Typed into tuicr after the draft, before the batch went out.
  w.comments = [
    ...COMMENTS,
    {
      ...COMMENT,
      id: "c3",
      start_line: 12,
      content: "while you were reading",
      created_at: new Date(NOW + MINUTE + 30_000).toISOString().replace("Z", "+00:00"),
    },
  ];
  await w.clock.advance(MINUTE);
  await send($, w.box);
  expect(claimOf(w)).toMatchObject({ slug: SLUG, seen: [] });

  w.fills = [];
  await w.clock.advance(MINUTE);
  await send($, "something else");
  expect(w.fills).toHaveLength(1);
  expect(w.fills[0]).toContain("while you were reading");
});

test("a claim another session holds is left alone", async ($, on) => {
  const held = JSON.stringify({
    v: 1,
    root: ROOT,
    session: "another-session",
    harness: "pi",
    pid: 999,
    slug: SLUG,
    scope: { mode: "worktree", args: ["-w"] },
    seen: [],
    at: new Date(NOW - MINUTE).toISOString(),
  });
  const w = world(on, { claim: held });
  await start($, on);
  w.box = "my own draft";
  await send($, "carry on");
  expect(w.fills).toEqual([]);
  expect(w.files.get(CLAIM)).toBe(held);
});
