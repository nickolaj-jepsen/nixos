/**
 * The human side: `/memory` and the operations behind it. The browser and the
 * subcommands share one implementation of forget, promote, edit and priority.
 */
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { openBrowser, type BrowserAction } from "./browser.ts";
import { renderReview, review } from "./review.ts";
import type { Sessions } from "./session.ts";
import {
  copyEntry,
  deleteEntry,
  loadStore,
  loadStoreCached,
  memoryDir,
  parseEntry,
  pruneStore,
  updateEntryFile,
  writeEntry,
  type Entry,
  type Scope,
  type Store,
} from "./store.ts";
import { STATUS_MARK, verify } from "./verify.ts";

type Target = "main" | "global";

export function registerCommands(pi: ExtensionAPI, sessions: Sessions) {
  const find = (scope: Scope, id: string): Entry | undefined => {
    for (const store of [...scope.visible, ...scope.orphans]) {
      const match = loadStoreCached(store).find((entry) => entry.id === id);
      if (match) return match;
    }
    return undefined;
  };

  const targetStore = (scope: Scope, target: Target): Store | undefined =>
    target === "global" ? scope.global : scope.visible.find((store) => store.origin === "main");

  async function forget(ctx: ExtensionCommandContext, entry: Entry) {
    if (!(await ctx.ui.confirm("Forget this memory?", `${entry.statement}\n\n${entry.file}`)))
      return;
    await deleteEntry(entry);
    sessions.refresh(ctx, entry.store);
    ctx.ui.notify(`Forgot ${entry.id}`, "info");
  }

  async function promote(ctx: ExtensionCommandContext, scope: Scope, entry: Entry, target: Target) {
    const store = targetStore(scope, target);
    if (!store) {
      ctx.ui.notify("No main checkout store to promote into.", "warning");
      return;
    }
    if (entry.store.dir === store.dir) {
      ctx.ui.notify(`Already in ${store.origin} memory`, "info");
      return;
    }
    const name = `  ${entry.id}: ${entry.statement}`;
    if (!(await ctx.ui.confirm(`Promote to ${store.origin} memory?`, `${name}\n\n${store.dir}`)))
      return;
    await copyEntry(entry, store);
    sessions.refresh(ctx, store);
    ctx.ui.notify(`Promoted ${entry.id} to ${store.origin}`, "info");
  }

  async function edit(ctx: ExtensionCommandContext, entry: Entry) {
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
    sessions.refresh(ctx, entry.store);
  }

  async function adjustPriority(ctx: ExtensionCommandContext, entry: Entry, delta: number) {
    if (!entry.store.writable) {
      ctx.ui.notify(`${entry.id} is read-only here; promote it first.`, "warning");
      return;
    }
    await updateEntryFile(entry.file, entry.store, (current) => {
      current.priority = Math.max(0, Math.min(100, current.priority + delta));
      current.updated = new Date().toISOString();
    });
    sessions.refresh(ctx, entry.store);
  }

  async function runReview(ctx: ExtensionCommandContext, scope: Scope) {
    const text = renderReview(scope, review(scope));
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

  async function list(ctx: ExtensionCommandContext, scope: Scope) {
    const lines: string[] = [];
    for (const store of [...scope.visible, ...scope.orphans]) {
      const entries = loadStoreCached(store);
      lines.push(
        `${store.origin}${store.root ? ` (${store.root})` : ""}: ${entries.length} entries`,
      );
      for (const entry of entries) {
        lines.push(
          `  ${STATUS_MARK[verify(entry).status]} [${entry.priority}] ${entry.id} — ${entry.statement}`,
        );
      }
    }
    if (scope.visible.every((store) => loadStoreCached(store).length === 0))
      lines.push(`No memories yet under ${memoryDir()}`);
    ctx.ui.notify(lines.join("\n"), "info");
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
      const noun = entries.length === 1 ? "y" : "ies";
      if (!(await ctx.ui.confirm(`Drop ${entries.length} orphaned memor${noun}?`, names))) continue;
      for (const entry of entries) await deleteEntry(entry);
      removed += entries.length;
    }
    sessions.refresh(ctx);
    ctx.ui.notify(
      removed > 0 ? `Removed ${removed} orphaned memories` : "No orphaned memories to prune",
      "info",
    );
  }

  /** Runs a browser action; returns whether the browser should reopen. */
  async function apply(
    ctx: ExtensionCommandContext,
    scope: Scope,
    action: BrowserAction,
  ): Promise<boolean> {
    if (action.type === "review") {
      await runReview(ctx, scope);
      return false;
    }
    if (action.type === "promote") await promote(ctx, scope, action.entry, action.target);
    else if (action.type === "forget") await forget(ctx, action.entry);
    else if (action.type === "edit") await edit(ctx, action.entry);
    else await adjustPriority(ctx, action.entry, action.delta);
    return true;
  }

  /** The browser loop: each action returns control here, which reopens it. */
  async function browse(ctx: ExtensionCommandContext, scope: Scope) {
    if (!ctx.hasUI) {
      await list(ctx, scope);
      return;
    }
    for (;;) {
      const action = await openBrowser(ctx, scope, sessions.get(ctx).hot);
      if (!action || !(await apply(ctx, scope, action))) return;
    }
  }

  pi.registerCommand("memory", {
    description: "Browse, review, promote or forget memories (bare /memory opens the browser)",
    handler: async (args, ctx) => {
      const scope = sessions.get(ctx).scope;
      const [sub, id] = args.trim().split(/\s+/).filter(Boolean);
      if (sub === undefined) return browse(ctx, scope);
      if (sub === "list") return list(ctx, scope);
      if (sub === "review") return runReview(ctx, scope);
      if (sub === "prune") return prune(ctx, scope);
      if (sub === "promote" && !id) return browse(ctx, scope);
      if (sub === "promote" || sub === "forget" || sub === "edit") {
        const entry = id ? find(scope, id) : undefined;
        if (!entry) {
          ctx.ui.notify(id ? `No memory with id ${id}` : `Usage: /memory ${sub} <id>`, "error");
          return;
        }
        if (sub === "forget") return forget(ctx, entry);
        if (sub === "edit") return edit(ctx, entry);
        const targets: Target[] = scope.visible.some((store) => store.origin === "main")
          ? ["main", "global"]
          : ["global"];
        const choice =
          targets.length === 1
            ? targets[0]
            : await ctx.ui.select(`Promote ${entry.id} to`, targets);
        if (choice) await promote(ctx, scope, entry, choice as Target);
        return;
      }
      ctx.ui.notify(
        `Unknown /memory subcommand: ${sub}. Try list, review, promote, forget, edit, prune.`,
        "error",
      );
    },
  });
}
