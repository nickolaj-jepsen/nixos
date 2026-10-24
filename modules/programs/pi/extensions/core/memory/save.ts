/**
 * The write gate. A memory earns its place by passing a test, not by being
 * plausible: it must not be something the repo already answers, its citations
 * must resolve right now, it must not restate an entry that exists (unless it
 * says which one it replaces or differs from), and its statement must be a
 * rule rather than a status report.
 *
 * The gate is code, not prose in a tool description. Claude Code's corpus shows
 * what the model does with prose.
 */
import { join } from "node:path";
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

export type SaveRequest = {
  statement: string;
  kind: Kind;
  priority: number;
  whyNotDerivable: string;
  citations: Citation[];
  detail?: string;
  scope?: "project" | "global";
  replaces?: string;
  /** Id of an overlapping entry the save says is a different fact. */
  distinctFrom?: string;
  sourceSession?: string;
};

export type SaveOutcome =
  | { ok: true; entry: Entry; replaced: boolean }
  | { ok: false; error: string; candidates?: string[] };

const allEntries = (scope: Scope) => scope.visible.flatMap((store) => loadStoreCached(store));

/**
 * Validates `request` against the store it will land in and returns the entry to write.
 * `context` is the text pi already puts in the prompt; a statement it covers is rejected.
 */
export function planSave(request: SaveRequest, scope: Scope, context: string): SaveOutcome {
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
        'this directory is not in a git worktree, so there is no project memory to write. Save machine-wide facts with scope: "global", or start pi inside the repo.',
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
    id: slugify(statement),
    kind: request.kind,
    priority: Math.max(0, Math.min(100, Math.round(request.priority))),
    added: new Date().toISOString(),
    updated: new Date().toISOString(),
    sourceSession: request.sourceSession,
    whyNotDerivable: request.whyNotDerivable.trim(),
    citations: request.citations,
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

  if (context && coveredBy(statement, context))
    return {
      ok: false,
      error:
        "the context files or rules in your prompt already say this; they are the durable channel and need no memory copy",
    };

  const overlapping = entries
    .filter((entry) => entry !== replacing)
    .filter(
      (entry) =>
        nearDuplicate(draft, entry) ||
        overlap(tokenSet(statement), tokenSet(`${entry.statement} ${entry.detail}`)) >= 0.5,
    );
  if (request.distinctFrom && !entries.some((entry) => entry.id === request.distinctFrom))
    return {
      ok: false,
      error: `no entry with id ${request.distinctFrom} in a store this session can see`,
    };
  const distinct = overlapping.some((entry) => entry.id === request.distinctFrom);
  if (overlapping.length > 0 && !replacing && !distinct)
    return {
      ok: false,
      error:
        "this overlaps an existing memory. Re-save with replaces: <id> to update it, or distinct_from: <id> if it is a different fact.",
      candidates: overlapping.map(
        (entry) => `${entry.id} (${entry.store.origin}): ${entry.statement}`,
      ),
    };

  draft.id = replacing?.id ?? freeId(target, draft.id);
  draft.added = replacing?.added ?? draft.added;
  draft.file = join(target.dir, `${draft.id}.md`);
  return { ok: true, entry: draft, replaced: Boolean(replacing) };
}
