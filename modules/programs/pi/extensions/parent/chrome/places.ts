/**
 * The folder menu: this checkout in the apps this desktop runs, and its path on
 * the clipboard. `ctx.cwd` is the target, not the repository root, so a session
 * started in a package opens the package; Sublime Merge widens it to the
 * repository on its own. The path itself stays out of the rows: the footer above
 * the menu already shows it, and a row repeating it made the menu twice as wide
 * as its verbs.
 *
 * An app that is not installed keeps its row and says so, so the menu is in the
 * same order on every host and a missing shortcut reads as a missing app rather
 * than a shortcut that did nothing.
 */
import { appLabel, canLaunch, copyText, folderApps, launch } from "./apps.ts";
import type { Menu } from "./menu.ts";

export const folderMenu = (cwd: string): Menu => ({
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
      id: "copy",
      label: "Copy path",
      run: async (ctx) => {
        await copyText(cwd);
        ctx.ui.notify("chrome: path copied", "info");
      },
    },
  ],
});
