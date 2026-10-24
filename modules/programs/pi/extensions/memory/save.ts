/**
 * The write gate. A memory earns its place by passing a test, not by being
 * plausible: it must not be something the repo already answers, its citations
 * must resolve right now, it must not restate an entry that exists (unless it
 * says which one it replaces), and its statement must be a rule rather than a
 * status report.
 *
 * The gate is code, not prose in a tool description. Claude Code's corpus shows
 * what the model does with prose.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import type { Citation, Entry, Kind, Scope, Store } from "./store.ts";
import { STATEMENT_MAX, freeId, loadStoreCached, slugify } from "./store.ts";
import { coveredBy, nearDuplicate, overlap, tokenSet } from "./search.ts";
import { verify } from "./verify.ts";

/**
 * Statements that announce state instead of a fact. Bare labels only count as
 * the opening words ("TODO: ..."), so "git status is slow here" passes; the
 * phrases are unambiguous anywhere.
 */
const STATUS_WORDS =
  /^\W*(status|wip|todo|tbd|next steps?|in progress|milestone)\b|\b(this session|as of (?:today|now)|currently working)\b/i;

const CONTEXT_FILES = ["AGENTS.md", "AGENTS.MD", "AGENTS.override.md", "CLAUDE.md", "CLAUDE.MD"];

export type SaveRequest = {
  statement: string;
  kind: Kind;
  priority: number;
  tags: string[];
  whyNotDerivable: string;
  citations: Citation[];
  detail?: string;
  scope?: "project" | "global";
  whyGlobal?: string;
  replaces?: string;
  id?: string;
  sourceSession?: string;
};

export type SaveOutcome =
  | { ok: true; entry: Entry; replaced: boolean }
  | { ok: false; error: string; candidates?: string[] };

/** Context files pi already loads for this directory, nearest last. */
function contextText(cwd: string): string {
  const files: string[] = [];
  let dir = cwd;
  for (;;) {
    for (const name of CONTEXT_FILES) files.push(join(dir, name));
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  for (const name of CONTEXT_FILES) files.push(join(homedir(), ".pi", "agent", name));
  const seen = new Set<string>();
  const parts: string[] = [];
  for (const file of files) {
    if (!existsSync(file) || seen.has(file)) continue;
    seen.add(file);
    try {
      parts.push(readFileSync(file, "utf8"));
    } catch {
      // unreadable context file is not the memory's problem
    }
  }
  return parts.join("\n");
}

const allEntries = (scope: Scope) => scope.visible.flatMap((store) => loadStoreCached(store));

/** Validates `request` against the store it will land in and returns the entry to write. */
export function planSave(request: SaveRequest, scope: Scope): SaveOutcome {
  const statement = request.statement.replace(/\s+/g, " ").trim();
  if (statement.length === 0) return { ok: false, error: "statement is empty" };
  if (statement.length > STATEMENT_MAX)
    return {
      ok: false,
      error: `statement is ${statement.length} chars; keep it to ${STATEMENT_MAX} (move detail to the body)`,
    };
  if (STATUS_WORDS.test(statement))
    return {
      ok: false,
      error:
        "that reads as session status, which is what makes memory rot. Save a rule, preference, environment quirk or gotcha that will still be true next month; status belongs in the session or the repo.",
    };
  if (request.whyNotDerivable.trim().length < 10)
    return {
      ok: false,
      error:
        "why_not_derivable must say what an agent with this repo checked out would get wrong without the note, and why the repo cannot tell it.",
    };
  if (request.citations.length === 0)
    return { ok: false, error: "at least one citation is required" };
  for (const citation of request.citations) {
    if (citation.kind === "snippet" && !citation.path)
      return { ok: false, error: "a snippet citation needs the path it appears in" };
  }

  const wantsGlobal = request.scope === "global";
  if (!scope.project && !wantsGlobal)
    return {
      ok: false,
      error:
        'this directory is not in a git worktree, so there is no project memory to write. Save machine-wide facts with scope: "global" and why_global, or start pi inside the repo.',
    };
  if (wantsGlobal && (request.whyGlobal ?? "").trim().length < 10)
    return {
      ok: false,
      error: "why_global must say why this holds in every project, not just this one",
    };
  const target: Store = wantsGlobal ? scope.global : (scope.project as Store);

  const entries = allEntries(scope);
  const replacing = request.replaces
    ? entries.find((entry) => entry.id === request.replaces)
    : undefined;
  if (request.replaces && !replacing)
    return {
      ok: false,
      error: `no entry with id ${request.replaces} in a store this session can see`,
    };
  if (replacing && replacing.store !== target) {
    const where = replacing.store.writable
      ? "the main checkout's store"
      : `the ${replacing.store.origin} store`;
    return {
      ok: false,
      error: `${replacing.id} lives in ${where}, which this session cannot write. Ask the user to run /memory promote instead of forking it here.`,
    };
  }

  const draft: Entry = {
    id: request.id ? slugify(request.id) : slugify(statement),
    kind: request.kind,
    priority: Math.max(0, Math.min(100, Math.round(request.priority))),
    tags: request.tags.map((tag) => tag.trim().toLowerCase()).filter(Boolean),
    added: new Date().toISOString(),
    updated: new Date().toISOString(),
    sourceSession: request.sourceSession,
    whyNotDerivable: request.whyNotDerivable.trim(),
    whyGlobal: request.scope === "global" ? request.whyGlobal?.trim() : undefined,
    citations: request.citations,
    recallCount: replacing?.recallCount ?? 0,
    lastRecalled: replacing?.lastRecalled,
    statement,
    detail: (request.detail ?? "").trim(),
    file: "",
    store: target,
    extra: replacing?.extra ?? {},
  };

  const broken = verify(draft).checks.filter((check) => check.status === "stale");
  if (broken.length > 0)
    return {
      ok: false,
      error: `citation does not resolve now: ${broken.map((check) => check.note).join("; ")}`,
    };

  const context = contextText(scope.cwd);
  if (context && coveredBy(statement, context))
    return {
      ok: false,
      error:
        "AGENTS.md/CLAUDE.md already says this; that file is the durable channel and does not need a memory copy",
    };

  const candidates = entries
    .filter((entry) => entry !== replacing)
    .filter(
      (entry) =>
        nearDuplicate(draft, entry) ||
        overlap(tokenSet(statement), tokenSet(`${entry.statement} ${entry.detail}`)) >= 0.5,
    )
    .map((entry) => `${entry.id} (${entry.store.origin}): ${entry.statement}`);
  if (candidates.length > 0 && !request.replaces)
    return {
      ok: false,
      error:
        "this overlaps an existing memory. Re-save with replaces: <id> to update it, or say in detail what makes this a different fact.",
      candidates,
    };

  draft.id = replacing?.id ?? freeId(target, request.id ? slugify(request.id) : draft.id);
  draft.added = replacing?.added ?? draft.added;
  draft.file = join(target.dir, `${draft.id}.md`);
  return { ok: true, entry: draft, replaced: Boolean(replacing) };
}
