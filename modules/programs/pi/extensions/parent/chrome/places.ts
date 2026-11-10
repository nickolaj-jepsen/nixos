/**
 * The folder menu: this checkout in the apps this desktop runs, the checkout's
 * notes, and its path on the clipboard. `ctx.cwd` is the target, not the
 * repository root, so a session started in a package opens the package; Sublime
 * Merge widens it to the repository on its own. The path itself stays out of the
 * rows: the footer above the menu already shows it, and a row repeating it made
 * the menu twice as wide as its verbs.
 *
 * An app that is not installed keeps its row and says so, so the menu is in the
 * same order on every host and a missing shortcut reads as a missing app rather
 * than a shortcut that did nothing.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { formatAge } from "../lib/format.ts";
import {
  appLabel,
  canLaunch,
  copyText,
  folderApps,
  launch,
  openNote,
  preferredEditor,
} from "./apps.ts";
import type { Menu } from "./menu.ts";
import { storeNotes } from "./notes.ts";

/** Opens one of the checkout's notes in the editor: the only one, or the one picked, newest first. */
export const openNotes = async (ctx: ExtensionContext) => {
  const notes = storeNotes(ctx.cwd);
  let path = notes[0]?.path;
  if (!path) {
    ctx.ui.notify("chrome: no notes yet", "info");
    return;
  }
  if (notes.length > 1) {
    const labels = notes.map((n) => `${n.name} · ${formatAge(Date.now() - n.at, "now")}`);
    const picked = await ctx.ui.select("Notes", labels);
    if (picked === undefined) return;
    path = notes[labels.indexOf(picked)].path;
  }
  if (!(await openNote(path))) ctx.ui.notify(`chrome: no editor; ${path}`, "warning");
};

export const folderMenu = (cwd: string): Menu => {
  const editor = preferredEditor();
  return {
    title: "Open folder",
    // The editor is where the work continues, so it leads when it can run.
    preferred: canLaunch(editor, cwd) ? editor : undefined,
    rows: [
      ...folderApps.map((app) => ({
        id: app,
        label: appLabel(app),
        unavailable: canLaunch(app, cwd) ? undefined : "not installed",
        run: () => launch(app, cwd),
      })),
      {
        id: "notes",
        label: "Notes",
        run: (ctx) => openNotes(ctx),
      },
      {
        id: "copy",
        label: "Copy path",
        run: async (ctx) => {
          await copyText(cwd);
          ctx.ui.notify("chrome: path copied", "info");
        },
      },
    ],
  };
};
