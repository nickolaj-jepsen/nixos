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
const HUB = "/etc/profiles/per-user/me/bin/agent-hub";
const NOW = Date.UTC(2026, 9, 31, 12);
const HOUR = 3_600_000;
const SESSION = "11111111-2222-3333-4444-555555555555";

type Listed = { path: string; name: string; group: string; hours: number };

type Notes = {
  /** What `agent-hub notes` lists, in its order; undefined when the hub is down. */
  listed?: Listed[];
  /** Whether a bar takes `agent-hub show`. */
  bar?: boolean;
  /** What `command -v` finds, by name or absolute path. */
  installed?: string[];
};

type World = {
  /** Every argv the mod ran that was not a read-only question. */
  launched: string[][];
  copied: string[];
  /** The arguments of each `agent-hub show`. */
  shown: string[][];
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
  const w: World = { launched: [], copied: [], shown: [] };
  const installed = notes.installed ?? [OPENER, HUB];
  on("env.get", (_, e) => ({ value: ({ HOME, USER: "me" } as Record<string, string>)[e.name] }));
  on("clock.now", () => ({ value: NOW }));
  on("session.id", () => ({ value: SESSION }));
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
    if (argv[0] === HUB && argv[1] === "show") {
      w.shown.push(argv.slice(2));
      return ok("", notes.bar ? 0 : 1);
    }
    if (argv[0] === HUB && argv[1] === "notes") {
      if (!notes.listed) return ok("", 1);
      return ok(
        notes.listed
          .map(({ hours, ...note }) => `${JSON.stringify({ ...note, at: NOW - hours * HOUR })}\n`)
          .join(""),
      );
    }
    // `command -v` over a command's candidates.
    if (argv[0] === "sh" && (argv.includes("agent-note-open") || argv.includes("agent-hub"))) {
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

/** Everything the pane says. */
async function paneText($: Engine) {
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  const texts = await pane.findAll({ type: "Text" });
  await pane.unmount();
  return texts.map((t) => t.text).join(" ");
}

const NOTE = {
  path: `${NOTES}/nixos/findings.md`,
  name: "nixos/findings.md",
  group: "written",
  hours: 1,
};

test("/open plan goes to the bar's reader, naming this session, and opens no pane", async ($, on) => {
  const w = world(on, { notes: { bar: true, listed: [NOTE] } });
  await start($, on);
  await openPlan($);
  expect(w.shown).toEqual([["--session-id", SESSION]]);
  expect(await shownRows($)).toEqual([]);
});

test("with no bar, /open plan lists what the hub lists, in its order", async ($, on) => {
  world(on, {
    notes: {
      listed: [
        NOTE,
        { path: `${NOTES}/nixos/HANDOFF.md`, name: "nixos/HANDOFF.md", group: "read", hours: 3 },
        { path: `${NOTES}/nixos/old.md`, name: "nixos/old.md", group: "project", hours: 48 },
      ],
    },
  });
  await start($, on);
  await openPlan($);
  expect(await shownRows($)).toEqual([
    "nixos/findings.md 1h",
    "nixos/HANDOFF.md 3h read",
    "nixos/old.md 2d project",
  ]);
});

test("with no notes, /open plan says so and guesses nothing", async ($, on) => {
  world(on, { notes: { listed: [] } });
  await start($, on);
  await openPlan($);
  expect(await paneText($)).toContain("No notes yet.");
});

test("without the hub running, /open plan says what is missing", async ($, on) => {
  world(on);
  await start($, on);
  await openPlan($);
  expect(await paneText($)).toContain("agent-hub isn't running");
});

test("pressing a note hands its path to the opener", async ($, on) => {
  const w = world(on, { notes: { listed: [NOTE] } });
  await start($, on);
  await openPlan($);
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key: NOTE.path });
  await pane.unmount();
  expect(w.launched).toEqual([[OPENER, NOTE.path]]);
});

test("without the opener installed, a note opens in VS Code", async ($, on) => {
  const w = world(on, { notes: { listed: [NOTE], installed: ["code", HUB] } });
  await start($, on);
  await openPlan($);
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key: NOTE.path });
  await pane.unmount();
  expect(w.launched).toEqual([["/run/current-system/sw/bin/code", "--reuse-window", NOTE.path]]);
});

test("the folder menu's Notes row goes to the reader where there is one", async ($, on) => {
  const w = world(on, { notes: { bar: true, listed: [NOTE] } });
  await start($, on);
  await $.command.run({ ...RUN, command: "open" });
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key: "notes" });
  await pane.unmount();
  expect(w.shown).toEqual([["--session-id", SESSION]]);
});

test("the folder menu's Notes row switches the pane to the notes elsewhere", async ($, on) => {
  const w = world(on, { notes: { listed: [NOTE] } });
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
  expect(keys).toEqual(["code", "zed", "smerge", "files", "ghostty", "copy", "notes"]);
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
