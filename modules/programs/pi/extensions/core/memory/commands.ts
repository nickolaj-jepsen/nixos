/**
 * The human side: `/memory` and the operations behind it. The panel owns the
 * list and every action it can finish in place; this file owns the dialogs it
 * cannot (pi's editor, an agent turn) and the subcommands that work without a
 * TUI.
 */
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { MemoryBrowser, type BrowserEffect } from "./browser/index.ts";
import { buildModel, emptyLines, plainRows } from "./browser/rows.ts";
import { renderReview, review } from "./review.ts";
import type { Sessions } from "./session.ts";
import {
  copyEntry,
  deleteEntry,
  loadStore,
  loadStoreCached,
  parseEntry,
  pruneStore,
  updateEntryFile,
  writeEntry,
  type Entry,
  type Scope,
  type Store,
} from "./store.ts";

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

  /** Deletes an entry and repaints; the caller has already asked. */
  async function forgetNow(ctx: ExtensionCommandContext, entry: Entry) {
    await deleteEntry(entry);
    sessions.refresh(ctx, entry.store);
  }

  async function forget(ctx: ExtensionCommandContext, entry: Entry) {
    if (!(await ctx.ui.confirm("Forget this memory?", `${entry.statement}\n\n${entry.file}`)))
      return;
    await forgetNow(ctx, entry);
    ctx.ui.notify(`Forgot ${entry.id}`, "info");
  }

  /** Copies an entry into a store the session can write; the caller has already asked. */
  async function promoteNow(ctx: ExtensionCommandContext, entry: Entry, target: Target) {
    const store = targetStore(sessions.get(ctx).scope, target);
    if (!store) throw new Error("no main checkout to promote into");
    if (entry.store.dir === store.dir) throw new Error(`already in ${store.origin} memory`);
    await copyEntry(entry, store);
    sessions.refresh(ctx, store);
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

  /** The same rows the panel draws, without colour: `/memory list` and a headless run. */
  async function list(ctx: ExtensionCommandContext, scope: Scope) {
    const model = buildModel(scope, sessions.get(ctx).hot);
    const lines = model.rows.length === 0 ? emptyLines(scope) : plainRows(model);
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

  /**
   * The panel, reopened on the same row after the two actions that need their
   * own surface: pi's editor, and an agent turn that only recommends.
   */
  async function browse(ctx: ExtensionCommandContext, scope: Scope) {
    if (!ctx.hasUI || ctx.mode !== "tui") return list(ctx, scope);
    let initial: string | undefined;
    for (;;) {
      const effect = await ctx.ui.custom<BrowserEffect | undefined>(
        (tui, theme, _keybindings, done) =>
          new MemoryBrowser(
            tui,
            theme,
            {
              scope,
              reload: () => {
                sessions.refresh(ctx);
                return sessions.get(ctx).hot;
              },
              forget: (entry) => forgetNow(ctx, entry),
              promote: (entry, target) => promoteNow(ctx, entry, target),
              priority: (entry, delta) => adjustPriority(ctx, entry, delta),
            },
            done,
            initial,
          ),
        {
          overlay: true,
          // A browser reads best wide: the list and the detail both want the columns.
          overlayOptions: { anchor: "center", width: "92%", minWidth: 40, margin: 1 },
        },
      );
      if (!effect) return;
      if (effect.type === "review") return runReview(ctx, scope);
      await edit(ctx, effect.entry);
      initial = effect.entry.id;
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
