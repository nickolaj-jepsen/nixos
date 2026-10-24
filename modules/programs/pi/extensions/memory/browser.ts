/**
 * The `/memory` browser: a list of every entry the session can see, then the
 * actions for the one picked. It returns one action; the command handler
 * applies it and reopens the list, so a confirmation dialog never fights the
 * list for the keyboard.
 */
import type { ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import type { HotIndex } from "./hot.ts";
import type { Entry, Scope } from "./store.ts";
import { loadStoreCached } from "./store.ts";
import { STATUS_MARK, verify, type Verification } from "./verify.ts";

export type BrowserAction =
  | { type: "forget"; entry: Entry }
  | { type: "promote"; entry: Entry; target: "main" | "global" }
  | { type: "priority"; entry: Entry; delta: number }
  | { type: "edit"; entry: Entry }
  | { type: "review" };

const REVIEW = "Review the store";
const BACK = "Back";

const origin = (entry: Entry) =>
  entry.store.origin === "orphan" ? `orphan:${entry.store.label}` : entry.store.origin;

export async function openBrowser(
  ctx: ExtensionCommandContext,
  scope: Scope,
  hot: HotIndex,
): Promise<BrowserAction | undefined> {
  const stores = [...scope.visible, ...scope.orphans];
  const entries = stores
    .flatMap((store) => loadStoreCached(store))
    .sort((a, b) => b.priority - a.priority || origin(a).localeCompare(origin(b)));
  if (entries.length === 0) {
    ctx.ui.notify(
      `No memories yet. They live in ${scope.project?.dir ?? scope.global.dir}.`,
      "info",
    );
    return undefined;
  }
  const checked = new Map<Entry, Verification>(entries.map((entry) => [entry, verify(entry)]));
  const rows = new Map<string, Entry>();
  for (const entry of entries) {
    const mark = STATUS_MARK[checked.get(entry)!.status];
    rows.set(
      `${mark} ${String(entry.priority).padStart(3)} ${origin(entry)}/${entry.id} — ${entry.statement}`,
      entry,
    );
  }
  const title = `Memory · ${scope.project?.label ?? "no repo"} · hot ${hot.used}/${hot.budget} chars${hot.stale > 0 ? ` · ${hot.stale} stale` : ""}`;
  const hasMain = stores.some((store) => store.origin === "main");

  for (;;) {
    const picked = await ctx.ui.select(title, [...rows.keys(), REVIEW]);
    if (picked === undefined) return undefined;
    if (picked === REVIEW) return { type: "review" };
    const entry = rows.get(picked);
    if (!entry) return undefined;

    const verification = checked.get(entry)!;
    const actions = new Map<string, BrowserAction>([["Edit", { type: "edit", entry }]]);
    if (hasMain && entry.store.origin !== "main")
      actions.set("Promote to main", { type: "promote", entry, target: "main" });
    if (entry.store.origin !== "global")
      actions.set("Promote to global", { type: "promote", entry, target: "global" });
    actions.set("Priority +10", { type: "priority", entry, delta: 10 });
    actions.set("Priority -10", { type: "priority", entry, delta: -10 });
    actions.set("Forget", { type: "forget", entry });
    const about = [
      `${entry.id} [${entry.priority}, ${entry.kind}, ${origin(entry)}]: ${entry.statement}`,
      `cite: ${entry.citations.map((citation) => `${citation.kind} ${citation.value}`).join("; ")}`,
      `${STATUS_MARK[verification.status]} ${verification.checks.map((check) => check.note).join("; ") || "no citations"}`,
      entry.file,
    ].join("\n");
    const choice = await ctx.ui.select(about, [...actions.keys(), BACK]);
    const action = choice === undefined ? undefined : actions.get(choice);
    if (action) return action;
  }
}
