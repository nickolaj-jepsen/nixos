/**
 * A4's scenario fixture: a review entry with two comments waiting, written the
 * way the extension writes one, by an extension rather than by the shipped
 * modules. A2's opener records the same entry after a real review
 * (scenario/fixture-review.ts is A5's version of this).
 *
 * The progress is 1 of 2 files, so the border's segment reads
 * `review 2 new · 1/2` (D10) and the overlay's title has a count to show.
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

type Entry = { items?: Item[]; seen?: string[]; sent?: string[] };

const at = "2026-11-03T21:12:12.088148037+00:00";

/** Two comments: one on a single line, one over a range, both with a body to wrap. */
const ITEMS: readonly Item[] = [
  {
    id: "fixture-1",
    path: "src/a.ts",
    startLine: 42,
    endLine: 42,
    side: "new",
    type: "issue",
    author: "Nickolaj",
    body: "guard the empty token",
    at,
  },
  {
    id: "fixture-2",
    path: "src/b.ts",
    startLine: 7,
    endLine: 9,
    side: "new",
    type: "nit",
    author: "Nickolaj",
    body: "rename this once the callers are moved",
    at,
  },
];

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    // The same read the extension does: the last review entry on the branch.
    let previous: Entry | undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === "review") previous = entry.data as Entry;
    }
    const known = new Set((previous?.items ?? []).map((item) => item.id));
    const items = [...(previous?.items ?? []), ...ITEMS.filter((item) => !known.has(item.id))];
    pi.appendEntry("review", {
      v: 1,
      root: ctx.cwd,
      cwd: ctx.cwd,
      harness: "pi",
      slug: SLUG,
      args: ["-w"],
      socket: join(process.env.XDG_RUNTIME_DIR ?? "/tmp", "pi-review", "fixture.sock"),
      items,
      seen: items.map((item) => item.id),
      sent: previous?.sent ?? [],
      progress: { reviewedCount: 1, fileCount: 2 },
      at: new Date().toISOString(),
    });
    // The pane is what the scenario reads, so the fixture says what it wrote.
    ctx.ui.setWidget("fixture", [`fixture: review entry ${items.length} items`]);
  });
}
