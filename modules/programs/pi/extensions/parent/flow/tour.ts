/**
 * The review tour (C3, D17, D24): seeds the branch's diff as tuicr comments
 * authored `Flow`, so a large change arrives with a reading order instead of a
 * wall of hunks, and the human reopens the same session with the `/rv` line the
 * guide prints.
 *
 * tuicr ties a session to its exact argv, its checkout and its branch, so the
 * argv is computed here once and stored in `FLOW.json.tour` beside the slug
 * tuicr printed. Nothing computes the slug: it is parsed from stderr (GOTCHAS).
 *
 * A stop is anchored at a line number, and tuicr stores a line the diff does not
 * contain without ever rendering it, so every stop is checked against the diff
 * before any comment is added.
 */
import { spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { TOUR_AUTHOR } from "../review/ingest.ts";
import { type Flow, type FlowTour, TOOL_TOUR, type TourSpec, type TourStop } from "./contracts.ts";
import { flowOf, mergeBase, readFlow, writeFlow } from "./state.ts";

/** A big branch's zero-context diff is a few MB; a runaway one is cut off. */
const MAX_OUTPUT = 32 << 20;
/** The headless session fails fast when there is no terminal; a hung binary must not hang the guide. */
const TIMEOUT_MS = 20_000;

/** What one subprocess printed, and how it exited. */
export type Command = { code: number; stdout: string; stderr: string };

/** The two binaries this module runs, as one seam so a test answers without either. */
export type TourRunner = (command: string, args: string[], cwd: string) => Promise<Command>;

/** The installed binaries. */
export const runCommand: TourRunner = (command, args, cwd) =>
  new Promise((resolve) => {
    // A closed stdin is what tuicr's TUI start expects: EOF takes the same path
    // as `</dev/null`, and the session is persisted before the terminal fails.
    const child = spawn(command, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    const out: string[] = [];
    const err: string[] = [];
    let size = 0;
    const collect = (into: string[]) => (chunk: string) => {
      into.push(chunk);
      size += chunk.length;
      if (size > MAX_OUTPUT) child.kill();
    };
    child.stdout.setEncoding("utf8").on("data", collect(out));
    child.stderr.setEncoding("utf8").on("data", collect(err));
    const timer = setTimeout(() => child.kill(), TIMEOUT_MS);
    const done = (code: number) => {
      clearTimeout(timer);
      resolve({ code, stdout: out.join(""), stderr: err.join("") });
    };
    child.on("error", (error) => {
      err.push(String(error));
      done(1);
    });
    child.on("close", (code) => done(code ?? 1));
  });

// ── the argv the human will run too (D24) ───────────────────────────────────

/**
 * The argv `/rv` opens the tour with: the commit range from the merge base to
 * the branch, which is the diff the review is about. `-w` is left out on
 * purpose: it enters the slug, and the tour is about the branch's commits.
 */
export const tourArgv = (from: string, branch: string): string[] => ["-r", `${from}..${branch}`];

/** The line the guide prints and the owner types: the shortcut, then the same argv. */
export const tourRv = (from: string, branch: string): string =>
  `/rv ${tourArgv(from, branch).join(" ")}`;

/** tuicr's one line on stderr naming the session it opened, or undefined when it printed none. */
export const parseSessionSlug = (stderr: string): string | undefined => {
  let slug: string | undefined;
  for (const raw of stderr.split("\n")) {
    const line = raw.trim();
    if (!line.startsWith("tuicr-session: ")) continue;
    const value = line.slice("tuicr-session: ".length).trim();
    if (value !== "") slug = value;
  }
  return slug;
};

// ── the diff's line numbers ────────────────────────────────────────────────

/** One file of the diff: the lines each side offers as an anchor. */
export type FileAnchors = { old: Set<number>; new: Set<number> };

/** Every file the diff touches, keyed by the path as the diff names it. */
export type DiffAnchors = Map<string, FileAnchors>;

const HUNK = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

/** `a/foo.ts` or `b/foo.ts` as `foo.ts`; `/dev/null` as undefined. */
const sidePath = (value: string): string | undefined => {
  const path = value.split("\t")[0].trim();
  if (path === "" || path === "/dev/null") return undefined;
  return path.startsWith("a/") || path.startsWith("b/") ? path.slice(2) : path;
};

const addRange = (lines: Set<number>, start: number, count: number) => {
  for (let line = start; line < start + count; line += 1) lines.add(line);
};

/**
 * The lines each side of a zero-context diff changed, from its hunk headers. A
 * file with no hunks (a binary change, a mode change) is still a file of the
 * diff, so a file-level stop anchors to it and a line stop on it is refused.
 */
export const diffAnchors = (diff: string): DiffAnchors => {
  const anchors: DiffAnchors = new Map();
  const file = (path: string): FileAnchors => {
    const known = anchors.get(path);
    if (known !== undefined) return known;
    const created: FileAnchors = { old: new Set(), new: new Set() };
    anchors.set(path, created);
    return created;
  };
  let path: string | undefined;
  for (const line of diff.split("\n")) {
    if (line.startsWith("--- ")) {
      path = sidePath(line.slice(4)) ?? path;
      continue;
    }
    if (line.startsWith("+++ ")) {
      // A deletion's new side is /dev/null: the old side's path is the file's.
      path = sidePath(line.slice(4)) ?? path;
      if (path !== undefined) file(path);
      continue;
    }
    const hunk = HUNK.exec(line);
    if (hunk === null || path === undefined) continue;
    const [, oldStart, oldCount, newStart, newCount] = hunk;
    addRange(file(path).old, Number(oldStart), oldCount === undefined ? 1 : Number(oldCount));
    addRange(file(path).new, Number(newStart), newCount === undefined ? 1 : Number(newCount));
  }
  return anchors;
};

/** What the diff offers the stop's path, for an error message. */
const offer = (anchors: FileAnchors, side: "old" | "new"): string => {
  const lines = [...anchors[side]];
  if (lines.length === 0) return `no ${side} lines`;
  const shown = lines.slice(0, 4).join(", ");
  return lines.length > 4 ? `${shown}, …` : shown;
};

/**
 * Why a stop cannot be anchored, or undefined when it can. tuicr accepts a line
 * the diff does not have and never renders it, so this is the only guard that
 * keeps a drifted tour from disappearing one stop at a time.
 */
export const stopProblem = (stop: TourStop, anchors: DiffAnchors): string | undefined => {
  const side = stop.side ?? "new";
  if (stop.file === undefined) {
    if (stop.line !== undefined || stop.endLine !== undefined)
      return "a stop with a line needs the file it is in";
    return undefined;
  }
  const where = stop.line === undefined ? stop.file : `${stop.file}:${stop.line}`;
  const known = anchors.get(stop.file);
  if (known === undefined) return `${where} is not a file of this diff`;
  if (stop.line === undefined) {
    if (stop.endLine !== undefined) return `${where} has an end line but no line`;
    return undefined;
  }
  const lines = known[side];
  if (!lines.has(stop.line))
    return `${where} is not a changed ${side} line of this diff (${offer(known, side)})`;
  if (stop.endLine === undefined) return undefined;
  if (stop.endLine < stop.line) return `${where} ends before it starts`;
  if (!lines.has(stop.endLine))
    return `${stop.file}:${stop.endLine} is not a changed ${side} line of this diff (${offer(known, side)})`;
  return undefined;
};

// ── seeding the session ────────────────────────────────────────────────────

/** Where the tour is seeded: the main checkout, the branch, and the merge base it diffs from. */
export type TourWhere = { repoMain: string; branch: string; from: string };

/** A seeded tour, or why it is not there. */
export type TourSeeded = { ok: true; tour: FlowTour; added: number } | { ok: false; error: string };

/** The one line of a failed command that explains it. */
const why = (command: Command): string => {
  const text = `${command.stderr}\n${command.stdout}`
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line !== "" && !line.startsWith("tuicr-session: "))
    .at(-1);
  return text ?? `exit ${command.code}`;
};

/** One `tuicr review add`: the flags tuicr reads, then the body as the last positional. */
const addArgs = (where: TourWhere, slug: string, stop: TourStop): string[] => {
  const args = [
    "review",
    "add",
    "--repo",
    where.repoMain,
    "--session",
    slug,
    "--username",
    TOUR_AUTHOR,
    "--type",
    stop.type,
  ];
  if (stop.file !== undefined) args.push("--target-file", stop.file);
  if (stop.line !== undefined) {
    args.push("--line", String(stop.line), "--side", stop.side ?? "new");
    if (stop.endLine !== undefined) args.push("--end-line", String(stop.endLine));
  }
  args.push(stop.body);
  return args;
};

/**
 * Creates the tuicr session headlessly, checks the stops against the diff, adds
 * them as `Flow`, and returns the tour to record. The session exists before the
 * first comment is added; a start with nothing to review prints no slug, which
 * is the error that says so.
 */
export const seedTour = async (
  run: TourRunner,
  where: TourWhere,
  spec: TourSpec,
): Promise<TourSeeded> => {
  const diff = await run(
    "git",
    ["diff", "--no-color", "--no-ext-diff", "--unified=0", `${where.from}..${where.branch}`, "--"],
    where.repoMain,
  );
  if (diff.code !== 0) return { ok: false, error: `git diff failed: ${why(diff)}` };
  const anchors = diffAnchors(diff.stdout);
  if (anchors.size === 0)
    return {
      ok: false,
      error: `nothing to tour: ${where.from}..${where.branch} changes no file`,
    };

  const problems: string[] = [];
  for (const [index, stop] of spec.stops.entries()) {
    const problem = stopProblem(stop, anchors);
    if (problem !== undefined) problems.push(`stop ${index + 1}: ${problem}`);
  }
  if (problems.length > 0)
    return { ok: false, error: `${problems.join("; ")}. Fix the stops and call flow_tour again.` };

  const argv = tourArgv(where.from, where.branch);
  // The update check is a network call this seeding does not need; it is not
  // part of the slug, so the stored argv stays exactly what `/rv` runs.
  const started = await run("tuicr", ["tui", ...argv, "--no-update-check"], where.repoMain);
  const slug = parseSessionSlug(started.stderr);
  if (slug === undefined)
    return {
      ok: false,
      error: `tuicr did not open a session: ${why(started)}`,
    };

  const comments: TourStop[] = [];
  if (spec.intro.trim() !== "") comments.push({ type: "note", body: spec.intro });
  comments.push(...spec.stops);
  for (const [index, stop] of comments.entries()) {
    const added = await run("tuicr", addArgs(where, slug, stop), where.repoMain);
    if (added.code !== 0)
      return {
        ok: false,
        error: `tuicr refused comment ${index} of ${comments.length} (session ${slug}): ${why(added)}`,
      };
  }

  return {
    ok: true,
    added: comments.length,
    tour: { slug, argv, cwd: where.repoMain, rv: tourRv(where.from, where.branch) },
  };
};

// ── the tool ───────────────────────────────────────────────────────────────

/** The error answer both refusals and failures read as. */
const refused = (text: string) => ({
  content: [{ type: "text" as const, text }],
  details: undefined,
  isError: true,
});

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

/** The flow and its merge base, or the refusal to answer with. */
const whereOf = (ctx: ExtensionContext): { flow: Flow; where: TourWhere } | { error: string } => {
  const here = flowOf(ctx);
  if (here.kind === "none")
    return { error: "flow_tour only works inside a flow session; start one with /flow <slug>." };
  if (here.kind === "corrupt") return { error: `flow_tour refused: ${here.error}` };
  const flow = here.flow;
  const from = mergeBase(flow.repoMain, flow.base, flow.branch);
  if (from === undefined)
    return {
      error: `flow_tour refused: ${flow.base} and ${flow.branch} share no commit in ${flow.repoMain}.`,
    };
  return { flow, where: { repoMain: flow.repoMain, branch: flow.branch, from } };
};

/** The `flow_tour` tool. Called once from the feature entry (C3). */
export const registerTour = (pi: ExtensionAPI) => {
  pi.registerTool({
    name: TOOL_TOUR,
    label: "Flow tour",
    description:
      "Seed the branch's diff as tuicr review comments under the author Flow: an intro plus one body per stop, each anchored to a line the diff contains. Returns the tuicr session slug and the /rv line that reopens it.",
    promptSnippet: "Seed the branch's diff as a review tour of tuicr comments.",
    parameters: Type.Object({
      intro: Type.String({
        description: "What the reviewer should keep in mind while reading the diff.",
      }),
      stops: Type.Array(
        Type.Object({
          file: Type.Optional(
            Type.String({ description: "Path in the diff, omitted for a review-level stop." }),
          ),
          line: Type.Optional(
            Type.Number({ description: "Line in the new (or old) side of the diff." }),
          ),
          endLine: Type.Optional(Type.Number({ description: "Last line of a ranged stop." })),
          side: Type.Optional(Type.Union([Type.Literal("old"), Type.Literal("new")])),
          type: Type.String({ description: "issue, suggestion, nit, note or praise." }),
          body: Type.String({ description: "What to look for, in one or two sentences." }),
        }),
      ),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const found = whereOf(ctx);
      if (!("flow" in found)) return refused(found.error);
      const seeded = await seedTour(runCommand, found.where, {
        intro: params.intro,
        stops: params.stops,
      });
      if (!seeded.ok) return refused(`flow_tour refused: ${seeded.error}`);
      try {
        // Re-read first: a tier edit or a judge verdict may have landed since
        // this turn began, and the tour is one field of that same file.
        const current = readFlow(found.flow.planDir);
        writeFlow({ ...(current.kind === "ok" ? current.flow : found.flow), tour: seeded.tour });
      } catch (error) {
        return refused(
          `flow_tour seeded ${seeded.tour.slug} but could not write FLOW.json: ${message(error)}`,
        );
      }
      return {
        content: [
          {
            type: "text" as const,
            text: `flow_tour: ${seeded.added} comments seeded in tuicr session ${seeded.tour.slug}. The owner reopens it with: ${seeded.tour.rv}`,
          },
        ],
        details: { slug: seeded.tour.slug, rv: seeded.tour.rv },
        isError: false,
      };
    },
  });
};
