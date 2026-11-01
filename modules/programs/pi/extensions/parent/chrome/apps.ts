/**
 * The desktop apps the folder menu hands a checkout to, the probes that keep a
 * missing one visible but unavailable, and the two doors to the outside world a
 * link needs: a URL in the browser and text on the clipboard.
 *
 * Linux and macOS only, since those are the desktops this flake builds. Each
 * launch is detached: the editor or file manager outlives the click, and pi is
 * never waiting on it.
 */
import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { delimiter, join } from "node:path";
import { copyToClipboard } from "@earendil-works/pi-coding-agent";
import { noteOpener } from "./notes.ts";

const MAC = process.platform === "darwin";

/** A command's absolute path on PATH, or undefined. */
const which = (command: string) =>
  (process.env.PATH ?? "")
    .split(delimiter)
    .filter(Boolean)
    .map((dir) => join(dir, command))
    .find((path) => existsSync(path));

const onPath = (command: string) => which(command) !== undefined;

/** A mac app bundle in the usual place, for a GUI that ships no CLI on PATH. */
const appBundle = (name: string) => MAC && existsSync(`/Applications/${name}.app`);

export const folderApps = ["code", "smerge", "files", "ghostty"] as const;
export type FolderApp = (typeof folderApps)[number];

export const appLabel = (app: FolderApp): string => {
  switch (app) {
    case "code":
      return "VS Code";
    case "smerge":
      return "Sublime Merge";
    case "files":
      return MAC ? "Finder" : "Files";
    case "ghostty":
      return "Ghostty";
  }
};

type Launch = { command: string; args: string[] };

/** A mac app bundle, opened with arguments; `open` needs it installed either way. */
const openBundle = (bundle: string, args: string[]): Launch | undefined =>
  appBundle(bundle) ? { command: "open", args: ["-a", bundle, ...args] } : undefined;

/** A second instance of a mac bundle, which Ghostty needs to take a directory. */
const openNewBundle = (bundle: string, args: string[]): Launch | undefined =>
  appBundle(bundle)
    ? { command: "open", args: ["-na", `${bundle}.app`, "--args", ...args] }
    : undefined;

/**
 * How to start an app on a directory, in this platform's words; undefined when
 * it is not installed. The mac GUI launches go through `open`, which does not
 * need the app's own CLI on PATH.
 */
const launcher = (app: FolderApp, cwd: string): Launch | undefined => {
  switch (app) {
    case "code":
      return (
        (onPath("code") ? { command: "code", args: [cwd] } : undefined) ??
        (MAC ? openBundle("Visual Studio Code", [cwd]) : undefined)
      );
    case "smerge":
      return (
        (onPath("smerge") ? { command: "smerge", args: [cwd] } : undefined) ??
        (MAC ? openBundle("Sublime Merge", [cwd]) : undefined)
      );
    case "files":
      if (MAC) return { command: "open", args: [cwd] };
      return onPath("nautilus")
        ? { command: "nautilus", args: [cwd] }
        : onPath("xdg-open")
          ? { command: "xdg-open", args: [cwd] }
          : undefined;
    case "ghostty":
      // A shortcut should open a fresh shell, not resume this session's work.
      if (MAC) return openNewBundle("Ghostty", [`--working-directory=${cwd}`]);
      return onPath("ghostty")
        ? { command: "ghostty", args: [`--working-directory=${cwd}`] }
        : undefined;
  }
};

const start = (command: string, args: string[]): Promise<void> =>
  new Promise((resolve, reject) => {
    const child = spawn(command, args, { detached: true, stdio: "ignore" });
    child.once("error", reject);
    child.once("spawn", () => {
      child.unref();
      resolve();
    });
  });

/** Whether this app can be started here, so its row can say why when it cannot. */
export const canLaunch = (app: FolderApp, cwd: string) => launcher(app, cwd) !== undefined;

/** Hands a directory to an app and returns once the process is running. */
export const launch = async (app: FolderApp, cwd: string): Promise<void> => {
  const target = launcher(app, cwd);
  if (!target) throw new Error(`${appLabel(app)} is not installed`);
  await start(target.command, target.args);
};

// `tuicr -w` exits on a clean tree, so that opens its commit picker instead. $0 is tuicr.
const REVIEW = 'if [ -n "$(git status --porcelain)" ]; then exec "$0" -w; fi; exec "$0"';

const isRepo = (cwd: string) =>
  new Promise<boolean>((resolve) =>
    execFile("git", ["-C", cwd, "rev-parse", "--git-dir"], (error) => resolve(!error)),
  );

/** Starts tuicr on a checkout in a new Ghostty window; throws when it can't. */
export const openReview = async (cwd: string): Promise<void> => {
  if (!(await isRepo(cwd))) throw new Error("not a git repository");
  // An absolute path: a mac app started through `open` does not get this PATH.
  const tuicr = which("tuicr");
  if (!tuicr) throw new Error("tuicr is not installed");
  const args = [`--working-directory=${cwd}`, "-e", "sh", "-c", REVIEW, tuicr];
  const target = MAC
    ? openNewBundle("Ghostty", args)
    : onPath("ghostty")
      ? { command: "ghostty", args }
      : undefined;
  if (!target) throw new Error("Ghostty is not installed");
  await start(target.command, target.args);
};

/** Shows a note in the notes viewer, else VS Code; false when neither is installed. */
export const openNote = async (path: string): Promise<boolean> => {
  const target = noteOpener(path);
  if (!target) return false;
  await start(target.command, target.args);
  return true;
};

/** Opens a URL in the desktop browser. */
export const openUrl = async (url: string): Promise<void> => {
  const browser = MAC ? "open" : "xdg-open";
  if (!onPath(browser)) throw new Error("no browser opener on PATH");
  await start(browser, [url]);
};

/** Puts text on the clipboard through pi, which knows the terminal's own way. */
export const copyText = (text: string) => copyToClipboard(text);
