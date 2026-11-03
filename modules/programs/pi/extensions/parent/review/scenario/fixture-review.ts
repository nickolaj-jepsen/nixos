/**
 * A5's scenario fixture: a review entry written the way the extension writes
 * one, by an extension rather than by the shipped modules. Until A2's opener
 * lands there is nothing that puts comments in the inbox, so this stands in for
 * it and stays inside the scenario folder: the shipped code keeps doing the
 * real work, and this only fills the branch (C1).
 *
 * It appends one more comment at every session_start, so a `/reload` shows up
 * as new pending work beside the comments already sent.
 */
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const SLUG = "fixture@main/staged-and-unstaged/1c65010";

type Item = {
  id: string;
  path: string | null;
  startLine: number | null;
  endLine: number | null;
  side: "old" | "new" | null;
  type: string | null;
  author: string | null;
  body: string;
  at: string;
};

type Entry = {
  items?: Item[];
  seen?: string[];
  sent?: string[];
};

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    // The same read the extension does: the last review entry on the branch.
    let previous: Entry | undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === "review") previous = entry.data as Entry;
    }
    const count = (previous?.items?.length ?? 0) + 1;
    const item: Item = {
      id: `fixture-${count}`,
      path: "a.ts",
      startLine: count,
      endLine: count,
      side: "new",
      type: "issue",
      author: "owner",
      body: `fixture comment ${count}`,
      at: new Date().toISOString(),
    };
    pi.appendEntry("review", {
      v: 1,
      root: ctx.cwd,
      cwd: ctx.cwd,
      harness: "pi",
      slug: SLUG,
      scope: { mode: "worktree", args: ["-w"] },
      socket: join(process.env.XDG_RUNTIME_DIR ?? "/tmp", "pi-review", "fixture.sock"),
      items: [...(previous?.items ?? []), item],
      seen: [...(previous?.seen ?? []), item.id],
      sent: previous?.sent ?? [],
      progress: { reviewedCount: 0, fileCount: 1 },
      at: new Date().toISOString(),
    });
    // The pane is what the scenario reads, so the fixture says what it wrote.
    ctx.ui.setWidget("fixture", [
      `fixture: review entry ${count} (sent ${previous?.sent?.length ?? 0})`,
    ]);
  });
}
