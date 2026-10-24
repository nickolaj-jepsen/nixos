/**
 * The review report: what the store can no longer back up. Deterministic, no
 * model call — staleness is re-checked against the tree and duplicates found by
 * token overlap. Review only recommends; nothing is deleted or rewritten from
 * here.
 */
import type { Entry, Scope } from "./store.ts";
import { loadStore } from "./store.ts";
import { nearDuplicate } from "./search.ts";
import { buildHotSection } from "./hot.ts";
import { verify } from "./verify.ts";

export type FindingKind = "stale" | "unverified" | "duplicate" | "orphan";

export type Finding = {
  kind: FindingKind;
  id: string;
  origin: Entry["store"]["origin"];
  note: string;
};

export type Review = {
  entries: number;
  findings: Finding[];
  hot: ReturnType<typeof buildHotSection>;
  skipped: string[];
};

/** Collects everything review can point at, cheapest checks first. */
export function review(scope: Scope): Review {
  const entries: Entry[] = [];
  const skipped: string[] = [];
  for (const store of scope.visible) {
    const loaded = loadStore(store);
    entries.push(...loaded.entries);
    skipped.push(...loaded.skipped);
  }
  for (const store of scope.orphans) {
    const loaded = loadStore(store);
    entries.push(...loaded.entries);
    skipped.push(...loaded.skipped);
  }

  const findings: Finding[] = [];
  for (const entry of entries) {
    const verification = verify(entry);
    if (entry.store.origin === "orphan") {
      findings.push({
        kind: "orphan",
        id: entry.id,
        origin: entry.store.origin,
        note: `worktree ${entry.store.label} is gone`,
      });
      continue;
    }
    const stale = verification.checks.filter((check) => check.status === "stale");
    if (stale.length > 0) {
      findings.push({
        kind: "stale",
        id: entry.id,
        origin: entry.store.origin,
        note: stale.map((check) => check.note).join("; "),
      });
    } else if (verification.status === "unverified" && entry.kind === "reference") {
      findings.push({
        kind: "unverified",
        id: entry.id,
        origin: entry.store.origin,
        note: "no citation this store can check",
      });
    }
  }

  const seen = new Set<string>();
  for (let i = 0; i < entries.length; i++) {
    for (let j = i + 1; j < entries.length; j++) {
      const [a, b] = [entries[i], entries[j]];
      const key = `${a.store.dir}/${a.id}|${b.store.dir}/${b.id}`;
      if (seen.has(key) || !nearDuplicate(a, b)) continue;
      seen.add(key);
      findings.push({
        kind: "duplicate",
        id: `${a.id} / ${b.id}`,
        origin: b.store.origin,
        note: `${a.store.origin} and ${b.store.origin} versions overlap`,
      });
    }
  }

  const visible = entries.filter((entry) => entry.store.origin !== "orphan");
  return { entries: entries.length, findings, hot: buildHotSection(visible, verify), skipped };
}

/** The review as text: for the agent turn and for a non-interactive terminal. */
export function renderReview(scope: Scope, report: Review): string {
  const lines: string[] = [];
  const hot = report.hot;
  lines.push(
    `Memory in ${scope.project?.root ?? scope.cwd}: ${report.entries} entr${report.entries === 1 ? "y" : "ies"}, hot section ${hot.used}/${hot.budget} chars, ${hot.cold} cold, ${hot.stale} stale.`,
  );
  if (report.findings.length === 0) {
    lines.push("Nothing to clean up: every citation resolves and nothing duplicates.");
    return lines.join("\n");
  }
  const order: FindingKind[] = ["stale", "orphan", "duplicate", "unverified"];
  const label: Record<FindingKind, string> = {
    stale: "Stale (citation no longer resolves)",
    orphan: "Orphaned (worktree removed)",
    duplicate: "Duplicates",
    unverified: "Unverifiable",
  };
  for (const kind of order) {
    const group = report.findings.filter((finding) => finding.kind === kind);
    if (group.length === 0) continue;
    lines.push("", `${label[kind]}:`);
    for (const finding of group)
      lines.push(`  [${finding.origin}] ${finding.id} — ${finding.note}`);
  }
  if (report.skipped.length > 0) {
    lines.push("", "Unparsed files (no statement, or broken frontmatter):");
    for (const file of report.skipped) lines.push(`  ${file}`);
  }
  lines.push(
    "",
    "Recommend only: nothing here has been changed. Repair an entry with memory_save (replaces: <id>), and let the user run /memory forget <id> for a removal.",
  );
  return lines.join("\n");
}
