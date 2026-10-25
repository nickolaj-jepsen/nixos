import { atom, read, update } from "claude-code";
import type { EngineInterface, ProcessRunResult, Register, RenderSurface } from "claude-code";

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

const PANE = "git-menu";
const TITLES: Record<MenuKind, string> = { git: "Git", folder: "Open folder" };
const HINTS = "1-9 or Enter picks · Esc closes";
const GIT_TIMEOUT_MS = 3000;
const GH_TIMEOUT_MS = 5000;
// Starts a GUI app without holding $.process.run, which waits for the output to close.
const DETACH = [
  "sh",
  "-c",
  'exec >/dev/null 2>&1 </dev/null; if command -v setsid >/dev/null; then exec setsid -f "$@"; fi; "$@" &',
  "sh",
];

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

const isOpen = async ($: EngineInterface) => (await $.ui.panes()).some((p) => p.id === PANE);

async function close($: EngineInterface) {
  await update($, menu, () => null);
  await $.ui.close({ id: PANE });
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
  const built = kind === "git" ? await buildGit($, cwd) : await buildFolder($, cwd);
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
    for (const [name, description] of [
      ["git", "Open the git menu: the repository, branch and pull request on the forge"],
      ["open", "Open the folder menu: this checkout in an editor, file manager or terminal"],
    ] as const) {
      await $.command
        .register({ name, description, immediate: true })
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

  on("command.run", { command: "open" }, async ($) => {
    await show($, "folder");
    return { text: "Opened the folder menu." };
  });

  on("ui.close", { id: PANE }, async ($, e, next) => {
    await update($, menu, () => null);
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
          <Text dimColor>Asking git…</Text>
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
};
