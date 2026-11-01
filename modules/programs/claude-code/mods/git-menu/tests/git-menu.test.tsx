import type { On } from "claude-code";
import { expect, test } from "claude-code/testing";
import type { Engine } from "claude-code/testing";

const PANE = {
  plugin: "git-menu",
  component: "Pane",
  requestId: "git-menu",
  props: {
    title: "Git",
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

const PR =
  '{"url":"https://github.com/me/repo/pull/12","number":12,"state":"OPEN","isDraft":false}';

const HOME = "/home/me";
const NOTES = `${HOME}/.local/share/agents`;
const OPENER = "/etc/profiles/per-user/me/bin/agent-note-open";
const NOW = Date.UTC(2026, 9, 31, 12);
const HOUR = 3_600_000;

type Write = { path: string; tool?: string; isError?: true };

type Notes = {
  /** Every file on disk, by absolute path, with its age in hours. */
  files?: Record<string, number>;
  /** The session's write tool calls, oldest first. */
  writes?: Write[];
  /** What `command -v` finds, by name or absolute path. */
  installed?: string[];
  /** The main checkout the session runs in. */
  repo?: string;
};

type World = {
  /** Every argv the mod ran that was not a read-only question. */
  launched: string[][];
  copied: string[];
};

const ok = (stdout: string, exitCode = 0, stderr = "") => ({
  value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false },
});

function world(
  on: On,
  {
    pr = PR as string | null,
    mac = false,
    notes = {} as Notes,
    /** The CLIs on PATH that /open diff looks for. */
    tools = ["tuicr", "ghostty"],
  } = {},
): World {
  const w: World = { launched: [], copied: [] };
  const files = new Map(
    Object.entries(notes.files ?? {}).map(([path, hours]) => [path, NOW - hours * HOUR]),
  );
  const installed = notes.installed ?? [OPENER];
  on("env.get", (_, e) => ({ value: ({ HOME, USER: "me" } as Record<string, string>)[e.name] }));
  on("clock.now", () => ({ value: NOW }));
  on("session.repo", () => ({
    value: { root: notes.repo ?? "/home/me/nixos", remote: null, internal: false, name: null },
  }));
  on("session.messages", () => ({
    value: (notes.writes ?? []).map((write, i) => ({
      role: "assistant" as const,
      text: "",
      toolUses: [
        {
          tool_use_id: `t${i}`,
          tool: write.tool ?? "Write",
          input: { file_path: write.path, content: "x" },
          ...(write.isError ? { isError: true as const } : {}),
        },
      ],
    })),
  }));
  on("fs.stat", (_, e) => {
    const mtimeMs = files.get(e.path);
    if (mtimeMs === undefined) throw new Error(`ENOENT: ${e.path}`);
    return { value: { kind: "file" as const, size: 1, mtimeMs, isLink: false } };
  });
  on("fs.list", (_, e) => {
    const prefix = `${e.path}/`;
    const entries = new Map<string, { kind: "file" | "dir"; mtimeMs: number }>();
    for (const [path, mtimeMs] of files) {
      if (!path.startsWith(prefix)) continue;
      const [name = "", ...rest] = path.slice(prefix.length).split("/");
      entries.set(name, rest.length ? { kind: "dir", mtimeMs: 0 } : { kind: "file", mtimeMs });
    }
    if (entries.size === 0) throw new Error(`ENOENT: ${e.path}`);
    return {
      value: [...entries].map(([name, entry]) => ({ name, size: 1, isLink: false, ...entry })),
    };
  });
  on("ui.open", () => ({ value: { isPlaced: true } }));
  on("ui.close", () => ({ value: undefined }));
  on("ui.panes", () => ({ value: [] }));
  on("ui.toast", () => ({ value: undefined }));
  on("ui.copy", (_, e) => {
    w.copied.push(e.text);
    return { value: { isCopied: true } };
  });
  on("session.cwd", () => ({ value: "/repo" }));
  on("fs.exists", () => ({ value: false }));
  on("process.run", (_, e) => {
    const argv = [...e.argv];
    const line = argv.join(" ");
    if (argv[0] === "uname") return ok(mac ? "Darwin\n" : "Linux\n");
    if (argv[0] === "gh")
      return pr === null ? ok("", 1, "no pull requests found for branch") : ok(pr);
    if (argv[0] === "git") {
      if (line.includes(" status ")) {
        return ok(
          "# branch.oid abc1234def\n# branch.head feat/x\n# branch.upstream origin/feat/x\n",
        );
      }
      if (line.includes("--get-regexp"))
        return ok("remote.origin.url git@github.com:me/repo.git\n");
      if (line.endsWith("branch.feat/x.remote")) return ok("origin\n");
      if (line.includes("symbolic-ref")) return ok("origin/main\n");
      if (line.endsWith("rev-parse --git-dir")) return ok(".git\n");
      return ok("", 1);
    }
    // `command -v` over the note opener's candidates.
    if (argv[0] === "sh" && argv.includes("agent-note-open")) {
      const hit = argv.slice(4).find((c) => installed.includes(c));
      if (!hit) return ok("", 1);
      return ok(`${hit.includes("/") ? hit : `/run/current-system/sw/bin/${hit}`}\n`);
    }
    if (argv[0] === "sh" && argv.includes("tuicr")) {
      const hits = argv.slice(4).filter((c) => tools.includes(c));
      return ok(hits.map((c) => `/run/current-system/sw/bin/${c}\n`).join(""));
    }
    // The probe for installed apps.
    if (argv[0] === "sh" && argv.includes("xdg-open") && argv.includes("nautilus")) {
      return ok("code\nxdg-open\n");
    }
    w.launched.push(argv.slice(4));
    return ok("");
  });
  return w;
}

async function start($: Engine, on: On) {
  on("command.register", (_, e) => ({ value: { command: e.name } }));
  on("session.start", (_, e) => ({ cwd: e.cwd }));
  await $.session.start({ cwd: "/repo", surface: "terminal", isInteractive: true });
}

test("/git opens the branch's pull request on the forge", async ($, on) => {
  const w = world(on);
  await start($, on);
  for (const surface of ["terminal", "desktop"] as const) {
    w.launched = [];
    await $.command.run({ ...RUN, command: "git" });
    const pane = await $.ui.mount({ ...PANE, surface });
    await pane.press({ key: "pr" });
    await pane.unmount();
    expect(w.launched).toEqual([["xdg-open", "https://github.com/me/repo/pull/12"]]);
  }
});

test("a row that cannot run starts nothing", async ($, on) => {
  const w = world(on);
  await start($, on);
  await $.command.run({ ...RUN, command: "git" });

  // The branch already has an open pull request, so there is none to create.
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key: "create" });
  await pane.unmount();
  expect(w.launched).toEqual([]);
});

test("without a pull request, create links the compare page into the default branch", async ($, on) => {
  const w = world(on, { pr: null });
  await start($, on);
  await $.command.run({ ...RUN, command: "git" });

  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key: "create" });
  await pane.unmount();
  expect(w.launched).toContainEqual([
    "xdg-open",
    "https://github.com/me/repo/compare/main...feat/x?expand=1",
  ]);
});

test("the copy row puts the branch name on the clipboard", async ($, on) => {
  const w = world(on);
  await start($, on);
  await $.command.run({ ...RUN, command: "git" });

  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key: "copy" });
  await pane.unmount();
  expect(w.copied).toEqual(["feat/x"]);
});

test("/open hands the checkout to an installed app and not to a missing one", async ($, on) => {
  const w = world(on);
  await start($, on);
  await $.command.run({ ...RUN, command: "open" });

  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key: "smerge" });
  expect(w.launched).toEqual([]);
  await pane.press({ key: "code" });
  await pane.unmount();
  expect(w.launched).toEqual([["code", "/repo"]]);
});

/** The pane's rows, top to bottom, as `label description`. */
async function shownRows($: Engine) {
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  const buttons = await pane.findAll({ type: "Button" });
  await pane.unmount();
  return buttons.map((b) => b.text.replace(/\s+/g, " ").trim());
}

const openPlan = ($: Engine) => $.command.run({ ...RUN, command: "open", args: "plan" });

test("/open plan lists the session's notes, the last one written first", async ($, on) => {
  world(on, {
    notes: {
      files: { [`${NOTES}/nixos/plans/a/PLAN.md`]: 3, [`${NOTES}/nixos/findings.md`]: 1 },
      writes: [
        { path: `${NOTES}/nixos/plans/a/PLAN.md` },
        { path: `${NOTES}/nixos/findings.md`, tool: "Edit" },
        { path: "/home/me/nixos/README.md" },
      ],
    },
  });
  await start($, on);
  await openPlan($);
  expect(await shownRows($)).toEqual(["nixos/findings.md 1h", "a/PLAN.md 3h"]);
});

test("a write that failed is not one of the session's notes", async ($, on) => {
  world(on, {
    notes: {
      files: { [`${NOTES}/nixos/a.md`]: 1, [`${NOTES}/nixos/b.md`]: 2 },
      writes: [{ path: `${NOTES}/nixos/a.md` }, { path: `${NOTES}/nixos/b.md`, isError: true }],
    },
  });
  await start($, on);
  await openPlan($);
  expect(await shownRows($)).toEqual(["nixos/a.md 1h"]);
});

test("superseded versions and annotate-plan's copy are not notes", async ($, on) => {
  const plan = `${NOTES}/nixos/plans/a`;
  world(on, {
    notes: {
      files: { [`${plan}/PLAN.md`]: 2, [`${plan}/PLAN.prev.md`]: 1, [`${plan}/history/1.md`]: 1 },
      writes: [
        { path: `${plan}/PLAN.md` },
        { path: `${plan}/PLAN.prev.md` },
        { path: `${plan}/history/1.md` },
      ],
    },
  });
  await start($, on);
  await openPlan($);
  expect(await shownRows($)).toEqual(["a/PLAN.md 2h"]);
});

test("with no notes this session, the project's newest note stands in", async ($, on) => {
  world(on, {
    notes: {
      files: {
        [`${NOTES}/other/newest.md`]: 1,
        [`${NOTES}/nixos/plans/a/HANDOFF.md`]: 5,
        [`${NOTES}/nixos/plans/a/history/HANDOFF.md`]: 2,
        [`${NOTES}/nixos/old.md`]: 9,
      },
      writes: [{ path: "/home/me/nixos/README.md" }],
    },
  });
  await start($, on);
  await openPlan($);
  expect(await shownRows($)).toEqual(["a/HANDOFF.md 5h"]);
});

test("with no notes in the project either, the newest note anywhere stands in", async ($, on) => {
  world(on, {
    notes: { files: { [`${NOTES}/other/newest.md`]: 1, [`${NOTES}/old/old.md`]: 9 } },
  });
  await start($, on);
  await openPlan($);
  expect(await shownRows($)).toEqual(["other/newest.md 1h"]);
});

test("two notes of one name in different dirs read apart", async ($, on) => {
  const notes = [`${NOTES}/pi/plans/x/PLAN.md`, `${NOTES}/wt/plans/x/PLAN.md`];
  world(on, {
    notes: { files: { [notes[0]!]: 2, [notes[1]!]: 1 }, writes: notes.map((path) => ({ path })) },
  });
  await start($, on);
  await openPlan($);
  expect(await shownRows($)).toEqual(["wt/plans/x/PLAN.md 1h", "pi/plans/x/PLAN.md 2h"]);
});

test("pressing a note hands its path to the opener", async ($, on) => {
  const note = `${NOTES}/nixos/findings.md`;
  const w = world(on, { notes: { files: { [note]: 1 }, writes: [{ path: note }] } });
  await start($, on);
  await openPlan($);
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key: note });
  await pane.unmount();
  expect(w.launched).toEqual([[OPENER, note]]);
});

test("without the opener installed, a note opens in VS Code", async ($, on) => {
  const note = `${NOTES}/nixos/findings.md`;
  const w = world(on, {
    notes: { files: { [note]: 1 }, writes: [{ path: note }], installed: ["code"] },
  });
  await start($, on);
  await openPlan($);
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key: note });
  await pane.unmount();
  expect(w.launched).toEqual([["/run/current-system/sw/bin/code", "--reuse-window", note]]);
});

test("the folder menu's Notes row switches the pane to the notes", async ($, on) => {
  const note = `${NOTES}/nixos/findings.md`;
  const w = world(on, { notes: { files: { [note]: 1 }, writes: [{ path: note }] } });
  await start($, on);
  await $.command.run({ ...RUN, command: "open" });
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key: "notes" });
  await pane.unmount();
  expect(w.launched).toEqual([]);
  expect(await shownRows($)).toEqual(["nixos/findings.md 1h"]);
});

test("bare /open still shows the folder menu", async ($, on) => {
  world(on);
  await start($, on);
  await $.command.run({ ...RUN, command: "open" });
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  const keys = (await pane.findAll({ type: "Button" })).map((b) => b.key);
  await pane.unmount();
  expect(keys).toEqual(["code", "smerge", "files", "ghostty", "copy", "notes"]);
});

const openDiff = ($: Engine) => $.command.run({ ...RUN, command: "open", args: "diff" });

test("/open diff starts tuicr on the checkout in Ghostty and tells the model", async ($, on) => {
  const w = world(on);
  await start($, on);
  const result = await openDiff($);
  expect(w.launched).toHaveLength(1);
  const [argv = []] = w.launched;
  expect(argv.slice(0, 3)).toEqual(["ghostty", "--working-directory=/repo", "-e"]);
  expect(argv.at(-1)).toBe("/run/current-system/sw/bin/tuicr");
  expect(result.context).toHaveLength(1);
});

test("/open diff without tuicr starts nothing", async ($, on) => {
  const w = world(on, { tools: ["ghostty"] });
  await start($, on);
  const result = await openDiff($);
  expect(w.launched).toEqual([]);
  expect(result.context).toBeUndefined();
});
