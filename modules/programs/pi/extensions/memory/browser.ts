/**
 * The `/memory` browser. Everything the extension can do to a store is reachable
 * from one screen: see what is hot and why, check whether a citation still
 * resolves, promote a worktree find to the main checkout or to the global store,
 * adjust priority, edit the Markdown, forget an entry, or start a review.
 *
 * The component returns one action and closes; the command handler applies it and
 * reopens the browser, so a confirmation dialog never fights the screen for the
 * keyboard.
 */
import type { ExtensionCommandContext, Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";
import type { Entry, Scope, Store } from "./store.ts";
import { loadStoreCached } from "./store.ts";
import { verify, type Verification } from "./verify.ts";
import type { HotIndex } from "./hot.ts";
import { rank } from "./search.ts";

export type BrowserAction =
  | { type: "forget"; id: string }
  | { type: "promote"; ids: string[]; target: "main" | "global" }
  | { type: "priority"; id: string; delta: number }
  | { type: "edit"; id: string }
  | { type: "review" };

const MARK: Record<Verification["status"], string> = { verified: "✓", stale: "✗", unverified: "?" };
const VISIBLE_ROWS = 12;

export async function openBrowser(
  ctx: ExtensionCommandContext,
  scope: Scope,
  hot?: HotIndex,
): Promise<BrowserAction | undefined> {
  const stores: Store[] = [...scope.visible, ...scope.orphans];
  const entries = stores.flatMap((store) => loadStoreCached(store));
  if (entries.length === 0) {
    ctx.ui.notify(
      `No memories yet. They live in ${stores[0]?.dir ?? "~/.pi/agent/memory"}.`,
      "info",
    );
    return undefined;
  }
  const verifications = new Map<string, Verification>();
  const status = (entry: Entry) => {
    let known = verifications.get(entry.file);
    if (!known) {
      known = verify(entry);
      verifications.set(entry.file, known);
    }
    return known;
  };

  return ctx.ui.custom<BrowserAction | undefined>((tui, theme, keybindings, done) => {
    let filter = "";
    let cursor = 0;
    let target: "main" | "global" = stores.some((store) => store.origin === "main")
      ? "main"
      : "global";
    const selected = new Set<string>();
    let cache: { width: number; key: string; lines: string[] } | undefined;

    const matching = () => {
      if (filter.trim() === "") {
        return [...entries].sort(
          (a, b) =>
            b.priority - a.priority ||
            a.store.origin.localeCompare(b.store.origin) ||
            a.id.localeCompare(b.id),
        );
      }
      return rank(entries, filter).map((hit) => hit.entry);
    };

    let shown = matching();
    const clamp = () => {
      cursor = Math.max(0, Math.min(shown.length - 1, cursor));
    };

    const window = () => {
      const start = Math.max(
        0,
        Math.min(cursor - Math.floor(VISIBLE_ROWS / 2), shown.length - VISIBLE_ROWS),
      );
      return {
        start: Math.max(0, start),
        rows: shown.slice(Math.max(0, start), Math.max(0, start) + VISIBLE_ROWS),
      };
    };

    const footer = (tw: Theme) =>
      tw.fg(
        "dim",
        "↑↓ move · ⏎ select · t target · p promote · d forget · e edit · +/- priority · r review · esc close",
      );

    const render = (width: number): string[] => {
      const key = [filter, cursor, target, [...selected].join(","), width, shown.length].join("|");
      if (cache && cache.key === key && cache.width === width) return cache.lines;
      const th = theme;
      const lines: string[] = [];
      const counts = stores
        .map((store) => `${store.origin} ${loadStoreCached(store).length}`)
        .join(" · ");
      const hotText = hot
        ? `hot ${hot.used}/${hot.budget}c${hot.stale > 0 ? ` · ${hot.stale} stale` : ""}`
        : "";
      lines.push(
        truncateToWidth(
          th.fg("accent", th.bold(" Memory ")) +
            th.fg("muted", `${scope.project?.label ?? "no repo"} · ${counts} · ${hotText}`),
          width,
        ),
      );
      lines.push(
        truncateToWidth(`${th.fg("dim", "filter:")} ${filter}${th.fg("accent", "█")}`, width),
      );
      lines.push(truncateToWidth(th.fg("borderMuted", "─".repeat(width)), width));

      const { start, rows } = window();
      if (start > 0) lines.push(truncateToWidth(th.fg("dim", `  ↑ ${start} more`), width));
      rows.forEach((entry, index) => {
        const absolute = start + index;
        const current = absolute === cursor;
        const verification = status(entry);
        const box = selected.has(entry.file) ? "[x]" : "[ ]";
        const mark = th.fg(
          verification.status === "verified"
            ? "success"
            : verification.status === "stale"
              ? "error"
              : "warning",
          MARK[verification.status],
        );
        const origin = th.fg("dim", entry.store.origin.padEnd(6));
        const id = th.fg(current ? "accent" : "text", entry.id);
        const statement = th.fg(current ? "text" : "muted", entry.statement);
        const prefix = `${current ? "▸" : " "} ${box} ${mark} ${String(entry.priority).padStart(3)} ${origin} `;
        lines.push(truncateToWidth(`${prefix}${id} ${statement}`, width));
      });
      const tail = shown.length - (start + rows.length);
      if (tail > 0) lines.push(truncateToWidth(th.fg("dim", `  ↓ ${tail} more`), width));

      const entry = shown[cursor];
      lines.push(truncateToWidth(th.fg("borderMuted", "─".repeat(width)), width));
      if (entry) {
        const verification = status(entry);
        if (entry.detail)
          lines.push(truncateToWidth(`  ${th.fg("muted", entry.detail.split("\n")[0])}`, width));
        lines.push(
          truncateToWidth(
            `  ${th.fg("dim", "cite:")} ${entry.citations.map((citation) => `${citation.kind} ${citation.value}`).join("; ")}`,
            width,
          ),
        );
        lines.push(
          truncateToWidth(
            `  ${th.fg(verification.status === "verified" ? "success" : verification.status === "stale" ? "error" : "warning", verification.checks.map((check) => check.note).join("; ") || "no citations")}`,
            width,
          ),
        );
        lines.push(
          truncateToWidth(
            `  ${th.fg("dim", `added ${entry.added.slice(0, 10)} · recalled ${entry.recallCount}× · ${entry.kind} · ${entry.tags.join(", ") || "no tags"}`)}`,
            width,
          ),
        );
        lines.push(truncateToWidth(`  ${th.fg("dim", entry.file)}`, width));
      }
      lines.push(
        truncateToWidth(
          th.fg(
            "dim",
            `  promote target: ${target}${selected.size > 0 ? ` · ${selected.size} selected` : ""}`,
          ),
          width,
        ),
      );
      lines.push(truncateToWidth(`  ${footer(th)}`, width));
      cache = { width, key, lines };
      return lines;
    };

    const invalidate = () => {
      cache = undefined;
    };

    return {
      render,
      invalidate,
      handleInput(data: string) {
        const refresh = () => {
          shown = matching();
          clamp();
          invalidate();
          tui.requestRender();
        };
        if (keybindings.matches(data, "tui.select.cancel")) {
          done(undefined);
          return;
        }
        if (keybindings.matches(data, "tui.select.up")) {
          cursor = Math.max(0, cursor - 1);
          invalidate();
          tui.requestRender();
          return;
        }
        if (keybindings.matches(data, "tui.select.down")) {
          cursor = Math.min(shown.length - 1, cursor + 1);
          invalidate();
          tui.requestRender();
          return;
        }
        if (keybindings.matches(data, "tui.select.confirm")) {
          const entry = shown[cursor];
          if (entry) {
            if (selected.has(entry.file)) selected.delete(entry.file);
            else selected.add(entry.file);
          }
          invalidate();
          tui.requestRender();
          return;
        }
        if (data === " " || data === "\t") {
          const entry = shown[cursor];
          if (entry) {
            if (selected.has(entry.file)) selected.delete(entry.file);
            else selected.add(entry.file);
          }
          invalidate();
          tui.requestRender();
          return;
        }
        const entry = shown[cursor];
        const chosen = () =>
          selected.size > 0
            ? ([...selected]
                .map((file) => entries.find((candidate) => candidate.file === file))
                .filter(Boolean) as Entry[])
            : entry
              ? [entry]
              : [];
        switch (data) {
          case "\x7f":
          case "\b":
            filter = filter.slice(0, -1);
            refresh();
            return;
          case "t":
            target =
              target === "main" && stores.some((store) => store.origin === "main")
                ? "global"
                : "main";
            if (!stores.some((store) => store.origin === "main")) target = "global";
            invalidate();
            tui.requestRender();
            return;
          case "p": {
            const picks = chosen().filter((candidate) => candidate.store.origin !== target);
            if (picks.length === 0) {
              invalidate();
              tui.requestRender();
              return;
            }
            done({ type: "promote", ids: picks.map((candidate) => candidate.id), target });
            return;
          }
          case "d":
            if (entry) done({ type: "forget", id: entry.id });
            return;
          case "e":
            if (entry) done({ type: "edit", id: entry.id });
            return;
          case "+":
          case "=":
            if (entry) done({ type: "priority", id: entry.id, delta: 10 });
            return;
          case "-":
            if (entry) done({ type: "priority", id: entry.id, delta: -10 });
            return;
          case "r":
            done({ type: "review" });
            return;
          default:
            if (data.length === 1 && data >= " " && data !== "\x1b") {
              filter += data;
              refresh();
            }
        }
      },
    };
  });
}
