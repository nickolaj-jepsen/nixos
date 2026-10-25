/** The model-facing tools: save, and transcript search. */
import { StringEnum, Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import type { HotIndex } from "./hot.ts";
import { planSave, type SaveRequest } from "./save.ts";
import type { Sessions } from "./session.ts";
import { searchSessions } from "./sessions.ts";
import {
  CITATION_KINDS,
  KINDS,
  STATEMENT_MAX,
  writeEntry,
  type Citation,
  type Entry,
} from "./store.ts";

export function registerTools(pi: ExtensionAPI, sessions: Sessions) {
  pi.registerTool({
    name: "memory_save",
    label: "Memory save",
    description:
      'Save one durable fact this repo cannot tell an agent to this project\'s memory (or the global store with scope: "global"). ' +
      "Only a rule, preference, environment quirk, gotcha or external reference that is still true next month. " +
      "Rejected for status/plans, for anything AGENTS.md or the repo already says, for citations that do not resolve, and for duplicates of an existing entry.",
    promptGuidelines: [
      "Save a memory yourself when you hit something the repo cannot explain: a failed attempt whose retry worked for an environment reason (direnv, nix, a missing or oddly-spelled tool), a correction from the user to a choice you made from principle, or something you had to leave the repo to learn. Cite the moment (the command, file or correction); no citation, no save.",
    ],
    parameters: Type.Object({
      statement: Type.String({
        description: `The fact, one line, under ${STATEMENT_MAX} chars. Imperative for a rule; present tense otherwise.`,
      }),
      kind: StringEnum(KINDS),
      priority: Type.Number({
        description:
          "0-100; higher enters the hot index first. Hard rules ~90, preferences ~60, trivia ~30.",
      }),
      why_not_derivable: Type.String({
        description:
          "What an agent with this repo checked out would get wrong without this note, and why reading the code does not answer it. With scope=global, also why it holds in every project.",
      }),
      citations: Type.Array(
        Type.Object({
          kind: StringEnum(CITATION_KINDS),
          value: Type.String({
            description: "Path, symbol, exact snippet, command, user quote, url, or session file.",
          }),
          path: Type.Optional(
            Type.String({ description: "File the snippet lives in, for kind=snippet." }),
          ),
        }),
        {
          minItems: 1,
          maxItems: 4,
          description: "Evidence that must resolve now: a path, symbol, snippet, command or quote.",
        },
      ),
      detail: Type.Optional(
        Type.String({ description: "Optional longer explanation or the command to run." }),
      ),
      scope: Type.Optional(StringEnum(["project", "global"] as const)),
      replaces: Type.Optional(Type.String({ description: "Id of the entry this corrects." })),
      distinct_from: Type.Optional(
        Type.String({
          description: "Id of an overlapping entry this is a different fact from.",
        }),
      ),
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const session = sessions.get(ctx);
      if (session.subagent)
        return {
          content: [
            { type: "text", text: "Subagents cannot write memory; report the fact to the parent." },
          ],
          details: undefined,
        };
      const request: SaveRequest = {
        statement: params.statement,
        kind: params.kind,
        priority: params.priority,
        whyNotDerivable: params.why_not_derivable,
        citations: params.citations as Citation[],
        detail: params.detail,
        scope: params.scope,
        replaces: params.replaces,
        distinctFrom: params.distinct_from,
        sourceSession: ctx.sessionManager.getSessionId(),
      };
      const outcome = planSave(request, session.scope, session.contextText);
      if (!outcome.ok) {
        const candidates = outcome.candidates?.length
          ? `\nExisting:\n${outcome.candidates.map((line) => `  ${line}`).join("\n")}`
          : "";
        return {
          content: [{ type: "text", text: `Not saved: ${outcome.error}${candidates}` }],
          details: { saved: false },
          isError: true,
        };
      }
      await writeEntry(outcome.entry);
      sessions.refresh(ctx, outcome.entry.store);
      const where = `${outcome.entry.store.origin} memory`;
      const hot = priorityNote(sessions.get(ctx).hot, outcome.entry);
      return {
        content: [
          {
            type: "text",
            text: `${outcome.replaced ? "Updated" : "Saved"} ${outcome.entry.id} in ${where}. ${hot}\nFile: ${outcome.entry.file}`,
          },
        ],
        details: { saved: true, id: outcome.entry.id, file: outcome.entry.file },
      };
    },
    renderResult(result, _options, theme) {
      const details = result.details as { saved?: boolean; id?: string } | undefined;
      if (!details?.saved) return new Text(theme.fg("warning", "not saved"), 0, 0);
      return new Text(theme.fg("success", `saved ${details.id}`), 0, 0);
    },
  });

  pi.registerTool({
    name: "session_search",
    label: "Session search",
    exposure: "codemode",
    description:
      "Search past pi session transcripts, and each session's label and summary, from this repo and its worktrees by default. For recovering why something was decided or what was tried before; results are quotes, not facts.",
    parameters: Type.Object({
      query: Type.String({
        description: "Words or phrase to look for in user and assistant messages.",
      }),
      scope: Type.Optional(StringEnum(["repo", "all"] as const)),
      since: Type.Optional(
        Type.String({ description: "ISO date; skip sessions started before it." }),
      ),
      includeSubagents: Type.Optional(Type.Boolean()),
      limit: Type.Optional(Type.Number({ description: "Maximum excerpts (default 5)." })),
    }),
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    async execute(_id, params, signal, _onUpdate, ctx) {
      const result = await searchSessions({
        query: params.query,
        scope: params.scope,
        since: params.since,
        includeSubagents: params.includeSubagents,
        limit: Math.max(1, Math.min(20, params.limit ?? 5)),
        cwd: ctx.cwd,
        currentSessionFile: ctx.sessionManager.getSessionFile(),
        signal,
      });
      const lines =
        result.hits.length === 0
          ? [`No transcript matches "${params.query}". Scanned ${result.scanned} session files.`]
          : result.hits.map(
              (hit) =>
                `[${hit.timestamp.slice(0, 16).replace("T", " ")} · ${hit.role} · ${hit.cwd}${hit.label ? ` · ${hit.label}` : ""}]\n${hit.excerpt}\n  session ${hit.session} · ${hit.file}`,
            );
      if (result.skipped > 0)
        lines.push(
          `(${result.skipped} session files skipped: too large, unreadable or past the cap)`,
        );
      return {
        content: [{ type: "text", text: lines.join("\n\n") }],
        details: { hits: result.hits.length, scanned: result.scanned },
      };
    },
  });
}

const priorityNote = (hot: HotIndex, entry: Entry) => {
  const picked = hot.picks.some(
    (pick) => pick.entry.id === entry.id && pick.entry.store.dir === entry.store.dir,
  );
  if (picked) return "It is in the hot index: the next session starts with it.";
  const floor = hot.picks.at(-1)?.entry.priority;
  return `It stays on disk only: the hot budget is ${hot.used}/${hot.budget} chars${
    floor === undefined ? "" : ` and cuts off below priority ${floor}`
  }${hot.stale > 0 ? ", stale entries are skipped" : ""}.`;
};
