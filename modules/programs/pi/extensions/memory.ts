/**
 * Memory: a small, verified, per-worktree store of the things an agent with
 * this repo checked out would otherwise get wrong.
 *
 * What it deliberately is not:
 * - not a log. Nothing is extracted automatically, no daily notes, no summary
 *   written at exit. Only explicit saves, and only through a gate.
 * - not free-form. A save carries a citation that has to resolve now, a reason
 *   the repo cannot answer the question, and a statement that is not status.
 * - not authoritative. Recall returns evidence with a citation and a freshness
 *   verdict; whatever the agent observes now wins.
 *
 * The store is Markdown, one file per memory; the hot section is a hard-capped
 * digest rendered once per session and frozen so the prompt prefix stays
 * cached. Everything else is pull-only.
 */
import { Type } from "@earendil-works/pi-ai";
import { StringEnum } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
  ExtensionToolContext,
} from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { readFileSync } from "node:fs";
import { buildHotSection, type HotIndex } from "./memory/hot.ts";
import { renderReview, review } from "./memory/review.ts";
import { planSave, type SaveRequest } from "./memory/save.ts";
import { rank } from "./memory/search.ts";
import { searchSessions } from "./memory/sessions.ts";
import {
  CITATION_KINDS,
  KINDS,
  copyEntry,
  deleteEntry,
  invalidateAll,
  invalidateStore,
  loadStore,
  loadStoreCached,
  memoryDir,
  parseEntry,
  pruneStore,
  resolveScope,
  updateEntryFile,
  writeEntry,
  type Citation,
  type Entry,
  type Scope,
  type Store,
} from "./memory/store.ts";
import { verify, type Status } from "./memory/verify.ts";
import { openBrowser, type BrowserAction } from "./memory/browser.ts";

const STATUS_MARK: Record<Status, string> = { verified: "✓", stale: "✗", unverified: "?" };

const STATUS_WORD: Record<Status, string> = {
  verified: "citation resolves",
  stale: "citation no longer resolves — do not rely on this",
  unverified: "citation cannot be checked here",
};

type SessionState = {
  scope: Scope;
  hot: HotIndex;
  subagent: boolean;
};

export default function (pi: ExtensionAPI) {
  // One runtime in the process serves the parent and every subagent session, so
  // state is per session id, never per cwd alone.
  const sessions = new Map<string, SessionState>();

  const sessionFor = (ctx: ExtensionContext): SessionState => {
    const id = ctx.sessionManager.getSessionId();
    const known = sessions.get(id);
    if (known && known.scope.cwd === ctx.cwd) return known;
    const scope = resolveScope(ctx.cwd);
    const entries = scope.visible.flatMap((store) => loadStoreCached(store));
    const hot = buildHotSection(entries, verify);
    // @gotgenes/pi-subagents writes child transcripts under <parent>/tasks.
    const subagent = ctx.sessionManager.getSessionDir().endsWith("/tasks");
    const state: SessionState = { scope, hot, subagent };
    sessions.set(id, state);
    return state;
  };

  const setStatus = (ctx: ExtensionContext) => {
    if (!ctx.hasUI) return;
    const { hot } = sessionFor(ctx);
    // The chrome footer drops statuses first when the line is tight; keep it short.
    const parts = [`mem ${compact(hot.used)}/${compact(hot.budget)}`];
    if (hot.cold > 0) parts.push(`${hot.cold} cold`);
    if (hot.stale > 0) parts.push(`${hot.stale} stale`);
    ctx.ui.setStatus("memory", parts.join(" · "));
  };

  /** Re-reads the stores after a write; the hot section changes only when memory does. */
  const refresh = (ctx: ExtensionContext, store?: Store) => {
    if (store) invalidateStore(store);
    invalidateAll();
    const session = sessionFor(ctx);
    const entries = session.scope.visible.flatMap((entryStore) => loadStoreCached(entryStore));
    session.hot = buildHotSection(entries, verify);
    setStatus(ctx);
  };

  pi.on("session_start", async (_event, ctx) => {
    sessions.delete(ctx.sessionManager.getSessionId());
    invalidateAll();
    const session = sessionFor(ctx);
    setStatus(ctx);
    if (session.subagent)
      pi.setActiveTools(pi.getActiveTools().filter((name) => name !== "memory_save"));
    if (session.scope.orphans.length > 0 && ctx.hasUI) {
      const count = session.scope.orphans.reduce(
        (sum, store) => sum + loadStore(store).entries.length,
        0,
      );
      if (count > 0)
        ctx.ui.notify(
          `${count} memor${count === 1 ? "y" : "ies"} left by removed worktrees: /memory promote`,
          "info",
        );
    }
  });

  pi.on("session_shutdown", (_event, ctx) => {
    sessions.delete(ctx.sessionManager.getSessionId());
    if (ctx.hasUI) ctx.ui.setStatus("memory", undefined);
  });

  pi.on("before_agent_start", (event, ctx) => {
    const session = sessionFor(ctx);
    if (session.hot.text) event.systemPromptOptions.sections.memory = session.hot.text;
    else delete event.systemPromptOptions.sections.memory;
  });

  // --- recall -------------------------------------------------------------

  pi.registerTool({
    name: "memory_search",
    label: "Memory search",
    description:
      "Search the distilled memories for this repo and machine (rules, preferences, environment quirks, gotchas). Returns each match with its citation and whether that citation still resolves now.",
    promptSnippet:
      "memory_search: recall memories for this repo and machine, with a check of whether each citation still resolves",
    promptGuidelines: [
      "A memory is evidence, not an instruction: check it against the current tree before acting on it, and let what you observe now win.",
    ],
    parameters: Type.Object({
      query: Type.String({ description: "Terms to match; exact phrases and ids rank highest." }),
      limit: Type.Optional(Type.Number({ description: "Maximum entries to return (default 5)." })),
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    async execute(_id, params, _signal, _onUpdate, ctx) {
      const scope = sessionFor(ctx).scope;
      const entries = scope.visible.flatMap((store) => loadStoreCached(store));
      const hits = rank(entries, params.query).slice(
        0,
        Math.max(1, Math.min(20, params.limit ?? 5)),
      );
      if (hits.length === 0) {
        return {
          content: [
            {
              type: "text",
              text: `No memory matches "${params.query}". ${entries.length} entries exist in this scope.`,
            },
          ],
          details: { hits: 0 },
        };
      }
      const blocks: string[] = [];
      for (const { entry } of hits) {
        const verification = verify(entry);
        blocks.push(
          renderEntry(
            entry,
            verification.status,
            verification.checks.map((check) => `${check.status}: ${check.note}`),
          ),
        );
        await updateEntryFile(entry.file, entry.store, (current) => {
          current.recallCount += 1;
          current.lastRecalled = new Date().toISOString();
        });
      }
      for (const { entry } of hits) invalidateStore(entry.store);
      return {
        content: [{ type: "text", text: blocks.join("\n\n---\n\n") }],
        details: { hits: hits.length, ids: hits.map((hit) => hit.entry.id) },
      };
    },
    renderResult(result, _options, theme) {
      const details = result.details as { hits?: number; ids?: string[] } | undefined;
      if (!details) return new Text("", 0, 0);
      return new Text(theme.fg("muted", `${details.hits ?? 0} hit(s)`), 0, 0);
    },
  });

  // --- write --------------------------------------------------------------

  pi.registerTool({
    name: "memory_save",
    label: "Memory save",
    description:
      'Save one durable fact this repo cannot tell an agent to this project\'s memory (or the global store with scope: "global"). ' +
      "Only a rule, preference, environment quirk, gotcha or external reference that is still true next month. " +
      "Rejected for status/plans, for anything AGENTS.md or the repo already says, for citations that do not resolve, and for duplicates of an existing entry.",
    promptGuidelines: [
      "Save a memory only when the user asks, or when you hit something an agent with this repo checked out would get wrong and the repo cannot tell them (environment quirks, hard rules, owner preferences). Never save plans, status, or anything the tree already documents.",
      "Before memory_save, run memory_search with the same query and pass that query: the gate rejects a save that overlaps an existing entry unless replaces names it.",
    ],
    parameters: Type.Object({
      statement: Type.String({
        description:
          "The fact, one line, under 200 chars. Imperative for a rule; present tense otherwise.",
      }),
      kind: StringEnum(KINDS),
      priority: Type.Number({
        description:
          "0-100; higher enters the hot index first. Hard rules ~90, preferences ~60, trivia ~30.",
      }),
      why_not_derivable: Type.String({
        description:
          "What an agent with this repo checked out would get wrong without this note, and why reading the code does not answer it.",
      }),
      citations: Type.Array(
        Type.Object({
          kind: StringEnum(CITATION_KINDS),
          value: Type.String({
            description: "Path, symbol, exact snippet, command, user quote, url, or session id.",
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
      query: Type.String({ description: "The memory_search query you ran before saving." }),
      detail: Type.Optional(
        Type.String({ description: "Optional longer explanation or the command to run." }),
      ),
      tags: Type.Optional(Type.Array(Type.String(), { description: "A few lowercase keywords." })),
      scope: Type.Optional(StringEnum(["project", "global"] as const)),
      why_global: Type.Optional(
        Type.String({
          description: "Required with scope=global: why this holds in every project.",
        }),
      ),
      replaces: Type.Optional(
        Type.String({
          description:
            "Id of the entry this corrects; required instead of adding a near-duplicate.",
        }),
      ),
      id: Type.Optional(
        Type.String({ description: "Slug to use instead of one derived from the statement." }),
      ),
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (sessionFor(ctx).subagent)
        return {
          content: [
            { type: "text", text: "Subagents cannot write memory; report the fact to the parent." },
          ],
          details: undefined,
        };
      const scope = sessionFor(ctx).scope;
      const request: SaveRequest = {
        statement: params.statement,
        kind: params.kind,
        priority: params.priority,
        tags: params.tags ?? [],
        whyNotDerivable: params.why_not_derivable,
        citations: params.citations as Citation[],
        query: params.query,
        detail: params.detail,
        scope: params.scope,
        whyGlobal: params.why_global,
        replaces: params.replaces,
        id: params.id,
        sourceSession: ctx.sessionManager.getSessionId(),
      };
      const outcome = planSave(request, scope);
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
      refresh(ctx, outcome.entry.store);
      const where =
        outcome.entry.store.origin === "global"
          ? "global memory"
          : `${outcome.entry.store.origin} memory`;
      const hot = priorityNote(sessionFor(ctx).hot, outcome.entry);
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

  // --- episodes -----------------------------------------------------------

  pi.registerTool({
    name: "session_search",
    label: "Session search",
    description:
      "Search past pi session transcripts (pull-only, read this repo's sessions by default). Use it to recover why something was decided or what was tried before; results are quoted transcripts, not facts.",
    parameters: Type.Object({
      query: Type.String({
        description: "Words or phrase to look for in user and assistant messages.",
      }),
      scope: Type.Optional(StringEnum(["repo", "all"] as const)),
      since: Type.Optional(
        Type.String({ description: "ISO date; skip sessions older than this." }),
      ),
      includeSubagents: Type.Optional(Type.Boolean()),
      limit: Type.Optional(Type.Number({ description: "Maximum excerpts (default 5)." })),
    }),
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    async execute(_id, params, _signal, _onUpdate, ctx) {
      const result = searchSessions({
        query: params.query,
        scope: params.scope,
        since: params.since,
        includeSubagents: params.includeSubagents,
        limit: Math.max(1, Math.min(20, params.limit ?? 5)),
        cwd: ctx.cwd,
        currentSessionFile: ctx.sessionManager.getSessionFile(),
      });
      const lines =
        result.hits.length === 0
          ? [`No transcript matches "${params.query}". Scanned ${result.scanned} session files.`]
          : result.hits.map(
              (hit) =>
                `[${hit.timestamp.slice(0, 16).replace("T", " ")} · ${hit.role} · ${hit.cwd}]\n${hit.excerpt}\n  session ${hit.session} · ${hit.file}`,
            );
      if (result.skipped > 0)
        lines.push(`(${result.skipped} session files skipped: too large or unreadable)`);
      return {
        content: [{ type: "text", text: lines.join("\n\n") }],
        details: { hits: result.hits.length, scanned: result.scanned },
      };
    },
  });

  // --- the human side -----------------------------------------------------

  pi.registerCommand("memory", {
    description: "Browse, review, promote or forget memories (bare /memory opens the browser)",
    handler: async (args, ctx) => {
      const scope = sessionFor(ctx).scope;
      const [sub, ...rest] = args.trim().split(/\s+/).filter(Boolean);
      switch (sub) {
        case undefined:
          await browse(ctx, scope);
          return;
        case "list":
          await list(ctx, scope);
          return;
        case "review":
          await runReview(ctx, scope);
          return;
        case "promote":
          await promote(ctx, scope, rest[0]);
          return;
        case "forget":
          await forget(ctx, scope, rest[0]);
          return;
        case "edit":
          await edit(ctx, scope, rest[0]);
          return;
        case "prune":
          await prune(ctx, scope);
          return;
        default:
          ctx.ui.notify(
            `Unknown /memory subcommand: ${sub}. Try list, review, promote, forget, edit, prune.`,
            "error",
          );
      }
    },
  });

  /** The browser loop: each action returns control here, which reopens it. */
  async function browse(ctx: ExtensionCommandContext, scope: Scope) {
    if (ctx.mode !== "tui") {
      await list(ctx, scope);
      return;
    }
    for (;;) {
      const action = await openBrowser(ctx, scope, sessionFor(ctx).hot);
      if (!action) return;
      const applied = await apply(ctx, scope, action);
      if (!applied) return;
    }
  }

  async function apply(
    ctx: ExtensionCommandContext,
    scope: Scope,
    action: BrowserAction,
  ): Promise<boolean> {
    switch (action.type) {
      case "review":
        await runReview(ctx, scope);
        return false;
      case "forget": {
        const entry = find(scope, action.id);
        if (!entry) return true;
        if (!(await ctx.ui.confirm("Forget this memory?", `${entry.statement}\n\n${entry.file}`)))
          return true;
        await deleteEntry(entry);
        refresh(ctx, entry.store);
        ctx.ui.notify(`Forgot ${entry.id}`, "info");
        return true;
      }
      case "promote": {
        const target =
          action.target === "global"
            ? scope.global
            : scope.visible.find((store) => store.origin === "main");
        if (!target) {
          ctx.ui.notify("No main checkout store to promote into.", "warning");
          return true;
        }
        const entries = action.ids
          .map((id) => find(scope, id))
          .filter((entry): entry is Entry => entry !== undefined && entry.store.dir !== target.dir);
        if (entries.length === 0) {
          ctx.ui.notify(`Already in ${target.origin} memory`, "info");
          return true;
        }
        const list = entries.map((entry) => `  ${entry.id}: ${entry.statement}`).join("\n");
        if (
          !(await ctx.ui.confirm(`Promote to ${target.origin} memory?`, `${list}\n\n${target.dir}`))
        )
          return true;
        for (const entry of entries) await copyEntry(entry, target);
        refresh(ctx, target);
        ctx.ui.notify(`Promoted ${entries.length} to ${target.origin}`, "info");
        return true;
      }
      case "priority": {
        const entry = find(scope, action.id);
        if (!entry) return true;
        if (!entry.store.writable) {
          ctx.ui.notify(`${entry.id} is read-only here; promote it first.`, "warning");
          return true;
        }
        await updateEntryFile(entry.file, entry.store, (current) => {
          current.priority = Math.max(0, Math.min(100, current.priority + action.delta));
          current.updated = new Date().toISOString();
        });
        refresh(ctx, entry.store);
        return true;
      }
      case "edit": {
        const entry = find(scope, action.id);
        if (!entry || !entry.store.writable) return true;
        const text = await ctx.ui.editor(`${entry.id}.md`, readFileSync(entry.file, "utf8"));
        if (text === undefined) return true;
        const parsed = parseEntry(text, entry.file, entry.store);
        if (!parsed) {
          ctx.ui.notify("That file has no statement line; nothing written.", "error");
          return true;
        }
        await writeEntry(parsed);
        refresh(ctx, entry.store);
        return true;
      }
    }
  }

  function find(scope: Scope, id: string): Entry | undefined {
    const stores = [...scope.visible, ...scope.orphans];
    for (const store of stores) {
      const match = loadStoreCached(store).find((entry) => entry.id === id);
      if (match) return match;
    }
    return undefined;
  }

  async function list(ctx: ExtensionCommandContext, scope: Scope) {
    const stores = [...scope.visible, ...scope.orphans];
    const lines: string[] = [];
    for (const store of stores) {
      const entries = loadStoreCached(store);
      lines.push(
        `${store.origin}${store.root ? ` (${store.root})` : ""}: ${entries.length} entries`,
      );
      for (const entry of entries) {
        const verification = verify(entry);
        lines.push(
          `  ${STATUS_MARK[verification.status]} [${entry.priority}] ${entry.id} — ${entry.statement}`,
        );
      }
    }
    if (scope.visible.every((store) => loadStoreCached(store).length === 0))
      lines.push(`No memories yet under ${memoryDir()}`);
    ctx.ui.notify(lines.join("\n"), "info");
  }

  async function runReview(ctx: ExtensionCommandContext, scope: Scope) {
    const report = review(scope);
    const text = renderReview(scope, report);
    if (!ctx.hasUI) {
      ctx.ui.notify(text, "info");
      return;
    }
    await pi.sendUserMessage(
      [
        "Memory review for this scope (generated, not a request to change anything yet):",
        "",
        text,
        "",
        "Go through the findings and recommend, per entry: keep, repair (with the corrected statement and citations), or forget. " +
          "Do not delete or rewrite anything yourself — memory_save with replaces repairs an entry, and removal is the user's /memory forget. " +
          "If a finding is a false positive, say so and why.",
      ].join("\n"),
    );
  }

  async function promote(ctx: ExtensionCommandContext, scope: Scope, id?: string) {
    if (!id) {
      await browse(ctx, scope);
      return;
    }
    const entry = find(scope, id);
    if (!entry) {
      ctx.ui.notify(`No memory with id ${id}`, "error");
      return;
    }
    const targets = [
      ...(scope.visible.some((store) => store.origin === "main") ? ["main"] : []),
      "global",
    ] as const;
    const choice =
      targets.length === 1
        ? targets[0]
        : await ctx.ui.select(`Promote ${entry.id} to`, [...targets]);
    if (!choice) return;
    const target =
      choice === "global" ? scope.global : scope.visible.find((store) => store.origin === "main");
    if (!target) return;
    if (target.dir === entry.store.dir) {
      ctx.ui.notify(`${entry.id} is already in ${target.origin} memory`, "info");
      return;
    }
    await copyEntry(entry, target);
    refresh(ctx, target);
    ctx.ui.notify(`Promoted ${entry.id} to ${target.origin}`, "info");
  }

  async function forget(ctx: ExtensionCommandContext, scope: Scope, id?: string) {
    const entry = id ? find(scope, id) : undefined;
    if (!entry) {
      ctx.ui.notify(id ? `No memory with id ${id}` : "Usage: /memory forget <id>", "error");
      return;
    }
    if (!(await ctx.ui.confirm("Forget this memory?", `${entry.statement}\n\n${entry.file}`)))
      return;
    await deleteEntry(entry);
    refresh(ctx, entry.store);
    ctx.ui.notify(`Forgot ${entry.id}`, "info");
  }

  async function edit(ctx: ExtensionCommandContext, scope: Scope, id?: string) {
    const entry = id ? find(scope, id) : undefined;
    if (!entry) {
      ctx.ui.notify(id ? `No memory with id ${id}` : "Usage: /memory edit <id>", "error");
      return;
    }
    if (!entry.store.writable) {
      ctx.ui.notify(
        `${entry.id} is read-only here; promote it first, or edit it from the main checkout.`,
        "warning",
      );
      return;
    }
    const text = await ctx.ui.editor(`${entry.id}.md`, readFileSync(entry.file, "utf8"));
    if (text === undefined) return;
    const parsed = parseEntry(text, entry.file, entry.store);
    if (!parsed) {
      ctx.ui.notify("That file has no statement line; nothing written.", "error");
      return;
    }
    await writeEntry(parsed);
    refresh(ctx, entry.store);
  }

  async function prune(ctx: ExtensionCommandContext, scope: Scope) {
    let removed = 0;
    for (const store of scope.orphans) {
      const entries = loadStore(store).entries;
      if (entries.length === 0) {
        pruneStore(store);
        continue;
      }
      const names = entries.map((entry) => `${entry.id}: ${entry.statement}`).join("\n");
      if (
        !(await ctx.ui.confirm(
          `Drop ${entries.length} orphaned memor${entries.length === 1 ? "y" : "ies"}?`,
          names,
        ))
      )
        continue;
      for (const entry of entries) await deleteEntry(entry);
      removed += entries.length;
    }
    refresh(ctx);
    ctx.ui.notify(
      removed > 0 ? `Removed ${removed} orphaned memories` : "No orphaned memories to prune",
      "info",
    );
  }
}

/** One entry as the model sees it on recall. */
function renderEntry(entry: Entry, status: Status, notes: string[]): string {
  const head = `${STATUS_MARK[status]} ${entry.id} [${entry.priority}, ${entry.kind}, ${entry.store.origin}] — ${entry.statement}`;
  const lines = [head];
  if (entry.detail) lines.push(entry.detail);
  lines.push(
    `citation: ${entry.citations.map((citation) => `${citation.kind} ${citation.value}`).join("; ")}`,
  );
  lines.push(`check: ${STATUS_WORD[status]}${notes.length ? ` (${notes.join("; ")})` : ""}`);
  lines.push(`why it is here: ${entry.whyNotDerivable}`);
  if (entry.tags.length > 0) lines.push(`tags: ${entry.tags.join(", ")}`);
  lines.push(`added ${entry.added.slice(0, 10)} · file ${entry.file}`);
  return lines.join("\n");
}

/** 1840 → "1.8k", for the footer. */
const compact = (count: number) =>
  count >= 1000 ? `${(count / 1000).toFixed(1)}k` : String(count);

const priorityNote = (hot: HotIndex | undefined, entry: Entry) => {
  if (!hot) return "Search for it with memory_search.";
  const picked = hot.picks.some(
    (pick) => pick.entry.id === entry.id && pick.entry.store.dir === entry.store.dir,
  );
  if (picked) return "It is in the hot index: the next session starts with it.";
  const floor = hot.picks.at(-1)?.entry.priority;
  return `It stays cold until searched for: the hot budget is ${hot.used}/${hot.budget} chars${
    floor === undefined ? "" : ` and cuts off below priority ${floor}`
  }${hot.stale > 0 ? ", stale entries are skipped" : ""}.`;
};
