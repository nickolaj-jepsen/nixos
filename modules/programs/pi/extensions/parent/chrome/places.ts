/**
 * The folder menu: this checkout in the apps this desktop runs, the session's
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
import { appLabel, canLaunch, copyText, folderApps, launch, openNote } from "./apps.ts";
import type { Menu } from "./menu.ts";
import { type FoundNotes, noteLabels } from "./notes.ts";

/** Opens the one note, or asks which of several. */
export const openNotes = async (ctx: ExtensionContext, found: FoundNotes) => {
  let path = found.notes[0]?.path;
  if (!path) {
    ctx.ui.notify("chrome: no notes yet", "info");
    return;
  }
  if (found.notes.length > 1) {
    const labels = noteLabels(found.notes);
    const picked = await ctx.ui.select("Notes", labels);
    if (picked === undefined) return;
    path = found.notes[labels.indexOf(picked)].path;
  }
  if (!(await openNote(path)))
    ctx.ui.notify(`chrome: no note viewer or VS Code; ${path}`, "warning");
};

export const folderMenu = (cwd: string, notes: FoundNotes): Menu => ({
  title: "Open folder",
  // The editor is where the work continues, so it leads when it can run.
  preferred: canLaunch("code", cwd) ? "code" : undefined,
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
      description: notes.fallback ? "latest" : `${notes.notes.length} this session`,
      unavailable: notes.notes.length === 0 ? "no notes yet" : undefined,
      run: (ctx) => openNotes(ctx, notes),
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
});
