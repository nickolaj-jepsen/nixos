/**
 * A4's two surfaces. The meter is D3/D10's text, so the cases pin it exactly:
 * the count of comments not delivered yet, the progress half, and nothing at
 * all without a review. The overlay is asserted by rendering it at the two
 * widths the acceptance uses — 60 and 160 columns — because a row that only
 * fits the wide terminal is the failure this item is meant to avoid.
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import type { Theme } from "@earendil-works/pi-coding-agent";
import { visibleWidth } from "@earendil-works/pi-tui";
import type { ReviewEnv } from "./env.ts";
import { readEntry, recordEntry } from "./entry.ts";
import { inboxMeter } from "./inbox.ts";
import { InboxOverlay, locate } from "./overlay.ts";
import { REVIEW_ENTRY, type InboxItem, type ReviewEntry } from "./types.ts";

/**
 * The theme with every style as a pass-through: the assertions then read the
 * text the owner sees, and the widths are the widths the layout computed.
 */
const theme = {
  fg: (_color: string, text: string) => text,
  bold: (text: string) => text,
} as unknown as Theme;

type Branch = { type: string; customType?: string; data?: unknown }[];

const session = () => {
  const branch: Branch = [];
  const ctx = { sessionManager: { getBranch: () => branch } } as unknown as Parameters<
    typeof readEntry
  >[1];
  const env = {
    pi: {
      appendEntry: (customType: string, data: unknown) => {
        branch.push({ type: "custom", customType, data });
      },
    },
  } as unknown as ReviewEnv;
  return { branch, ctx, env };
};

const item = (over: Partial<InboxItem> = {}): InboxItem => ({
  id: "a",
  path: "src/a.ts",
  startLine: 42,
  endLine: 42,
  side: "new",
  type: "issue",
  author: "Nickolaj",
  body: "guard the empty token",
  at: "2026-11-03T21:12:12.088148037+00:00",
  ...over,
});

const entry = (over: Partial<ReviewEntry> = {}): ReviewEntry => ({
  v: 1,
  root: "/work/repo",
  cwd: "/work/repo",
  harness: "pi",
  slug: "repo@main/staged-and-unstaged/9d1b591",
  args: ["-w"],
  socket: "/run/user/1000/pi-review/0123456789abcdef.sock",
  items: [
    item(),
    item({ id: "b", path: "src/b.ts", startLine: 7, endLine: 7, body: "rename this" }),
  ],
  seen: ["a", "b"],
  sent: [],
  progress: { reviewedCount: 1, fileCount: 2 },
  at: "2026-11-03T21:12:12.088148037+00:00",
  ...over,
});

/** Publishes an entry the way an ingest does, so the ctx-less meter can read it. */
const published = (over: Partial<ReviewEntry> = {}) => {
  const { branch, ctx, env } = session();
  recordEntry(env, ctx, entry(over));
  assert.equal(branch.length, 1);
  return { env };
};

test("the meter reads `review 2 new · 1/2` for two comments of a 1/2 review (D3, D10)", () => {
  const { env } = published();
  const meter = inboxMeter(env);
  assert.equal(meter?.text, "review 2 new · 1/2");
  assert.equal(meter?.id, "review");
  assert.equal(typeof meter?.action, "function");
});

test("a delivered comment is no longer new, and the progress stays", () => {
  const { env } = published({ sent: ["a"] });
  assert.equal(inboxMeter(env)?.text, "review 1 new · 1/2");
  assert.equal(typeof inboxMeter(env)?.action, "function");
});

test("with nothing new the segment is the progress alone, dim and not a control", () => {
  const { env } = published({ sent: ["a", "b"] });
  const meter = inboxMeter(env);
  assert.equal(meter?.text, "review 1/2");
  // No action: the border paints it dim and has nothing to light under the pointer.
  assert.equal(meter?.action, undefined);
});

test("a listing without a file count drops the progress half rather than say 0/0", () => {
  const { env } = published({ progress: { reviewedCount: 0, fileCount: 0 } });
  assert.equal(inboxMeter(env)?.text, "review 2 new");
  const sent = published({ progress: { reviewedCount: 0, fileCount: 0 }, sent: ["a", "b"] });
  assert.equal(inboxMeter(sent.env), undefined);
});

test("no review on the branch means no segment", () => {
  const { branch, ctx, env } = session();
  readEntry(env, ctx);
  assert.deepEqual(branch, []);
  assert.equal(inboxMeter(env), undefined);
});

/** What the overlay draws for one frame, with the terminal reduced to what it reads. */
const draw = (
  items: readonly InboxItem[],
  options: { width: number; rows?: number; sent?: string[]; keys?: string[] },
) => {
  let repaints = 0;
  const results: string[] = [];
  const copied: string[] = [];
  const overlay = new InboxOverlay(
    { rows: options.rows ?? 40, requestRender: () => (repaints += 1) },
    theme,
    items,
    new Set(options.sent ?? []),
    (result) => results.push(result),
    (chosen) => copied.push(locate(chosen) ?? ""),
  );
  for (const key of options.keys ?? []) overlay.handleInput(key);
  return {
    lines: overlay.render(options.width),
    results,
    copied,
    repaints: () => repaints,
    overlay,
  };
};

/** The row the cursor is on, without the frame and with its padding collapsed. */
const marked = (lines: readonly string[]) =>
  lines
    .filter((line) => line.includes("> "))
    .map((line) => line.replace(/[│]/g, "").replace(/\s+/g, " ").trim());

test("the overlay lists every comment, its body and the count at 60 and 160 columns", () => {
  for (const width of [60, 160]) {
    const lines = draw(entry().items, { width }).lines;
    const text = lines.join("\n");
    assert.match(text, /Review inbox · 2 new/);
    assert.match(text, /src\/a\.ts:42 {2}\[issue\] {2}Nickolaj/);
    assert.match(text, /guard the empty token/);
    assert.match(text, /src\/b\.ts:7 {2}\[issue\] {2}Nickolaj/);
    assert.match(text, /rename this/);
    assert.match(text, /j\/k move · y copy · enter review · esc close 1\/2/);
    // A row wider than the terminal wraps and reads as a clipped line.
    for (const line of lines) assert.equal(visibleWidth(line), width);
  }
});

test("widths below the frame's floor are floored, not overflowed", () => {
  const lines = draw(entry().items, { width: 12 }).lines;
  for (const line of lines) assert.equal(visibleWidth(line), 24);
});

test("j and k move the cursor and nothing else", () => {
  const first = draw(entry().items, { width: 60 });
  assert.deepEqual(marked(first.lines), ["> src/a.ts:42 [issue] Nickolaj"]);
  // k at the top stays put and does not ask for a repaint.
  first.overlay.handleInput("k");
  assert.equal(first.repaints(), 0);
  first.overlay.handleInput("j");
  assert.equal(first.repaints(), 1);
  const second = first.overlay.render(60);
  assert.deepEqual(marked(second), ["> src/b.ts:7 [issue] Nickolaj"]);
  // The arrow keys are the same move.
  first.overlay.handleInput("\u001b[B");
  assert.deepEqual(marked(first.overlay.render(60)), ["> src/b.ts:7 [issue] Nickolaj"]);
});

test("y copies the highlighted comment's location, and the cursor moves it", () => {
  const first = draw(entry().items, { width: 60, keys: ["y"] });
  assert.deepEqual(first.copied, ["src/a.ts:42"]);
  const second = draw(entry().items, { width: 60, keys: ["j", "y"] });
  assert.deepEqual(second.copied, ["src/b.ts:7"]);
});

test("a comment with a range copies the range, and one with no file copies nothing", () => {
  const ranged = item({ endLine: 48 });
  const copied = draw([ranged], { width: 60, keys: ["y"] }).copied;
  assert.deepEqual(copied, ["src/a.ts:42-48"]);
  const fileless = item({ path: null, startLine: null, endLine: null });
  assert.equal(locate(fileless), undefined);
  assert.deepEqual(draw([fileless], { width: 60, keys: ["y"] }).copied, [""]);
});

test("a delivered comment is drawn, and drawn as the dim one", () => {
  const lines = draw(entry().items, { width: 60, sent: ["a", "b"] }).lines.join("\n");
  assert.match(lines, /src\/a\.ts:42/);
  assert.match(lines, /Review inbox(?![^│\n]*new)/);
});

test("enter attaches and escape closes, once", () => {
  assert.deepEqual(draw(entry().items, { width: 60, keys: ["\r"] }).results, ["attach"]);
  assert.deepEqual(draw(entry().items, { width: 60, keys: ["\u001b"] }).results, ["close"]);
  assert.deepEqual(draw(entry().items, { width: 60, keys: ["\r", "\u001b"] }).results, ["attach"]);
});

test("a terminal too short for the list scrolls to the cursor instead of clipping", () => {
  const many = Array.from({ length: 6 }, (_, index) =>
    item({ id: `i${index}`, startLine: 10 + index, body: `comment ${index}` }),
  );
  const drawn = draw(many, { width: 60, rows: 14 });
  // 14 rows minus the transcript's reserve: the frame's rows plus its two borders.
  assert.ok(drawn.lines.length <= 14 - 8 + 2, `${drawn.lines.length} rows`);
  for (let step = 0; step < many.length; step += 1) {
    drawn.overlay.handleInput("j");
    const lines = drawn.overlay.render(60);
    assert.ok(lines.length <= 14 - 8 + 2);
    for (const line of lines) assert.equal(visibleWidth(line), 60);
    // The highlighted row is on screen whichever comment it is on.
    assert.equal(marked(lines).length, 1, `step ${step}: ${marked(lines).join(" | ")}`);
  }
  assert.match(drawn.overlay.render(60).join("\n"), /6\/6/);
});

test("comment text is drawn as text: control bytes never reach the terminal (B1)", () => {
  const hostile = item({ body: "clear\x1b[2Jthe\x07screen" });
  const text = draw([hostile], { width: 60 }).lines.join("\n");
  assert.ok(!text.includes("\x1b"), "an escape sequence survived");
  assert.match(text, /clearthescreen/);
});

test("the header is text too: path, type and author lose their escapes (B1)", () => {
  const hostile = item({
    path: "src/\x1b]52;c;aGFjaw==\x07a.ts",
    type: "issue\x1b[2J",
    author: "Nick\x1b[31molaj",
  });
  const text = draw([hostile], { width: 60 }).lines.join("\n");
  assert.ok(!text.includes("\x1b"), "an escape sequence survived");
  assert.match(text, /src\/a\.ts/);
  assert.match(text, /\[issue\]/);
  assert.match(text, /Nickolaj/);
});

test("a theme change asks for the repaint and changes nothing else", () => {
  const drawn = draw(entry().items, { width: 60 });
  const before = drawn.overlay.render(60);
  drawn.overlay.invalidate();
  assert.equal(drawn.repaints(), 1);
  assert.deepEqual(drawn.overlay.render(60), before);
});

test("an entry recorded under another custom type is not the meter's review", () => {
  const { branch, ctx, env } = session();
  branch.push({ type: "custom", customType: "agent-note", data: entry() });
  readEntry(env, ctx);
  assert.equal(inboxMeter(env), undefined);
  assert.equal(REVIEW_ENTRY, "review");
});
