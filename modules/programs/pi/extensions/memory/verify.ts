/**
 * Best-effort citation checking. A memory is only as good as the evidence it
 * cites, and that evidence can move. Machine-checkable citations (a path, a
 * symbol, a snippet, a command, a session file) are re-checked every time an
 * entry is shown; a quote or a URL cannot be checked here and is reported as
 * unverified rather than as current.
 *
 * The result is never "true": it says whether the citation still resolves, and
 * a stale entry is left out of the hot section until a human or agent fixes it.
 */
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { accessSync, constants } from "node:fs";
import { delimiter, isAbsolute, join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type { Citation, Entry } from "./store.ts";

export type Status = "verified" | "stale" | "unverified";
export type CitationCheck = { citation: Citation; status: Status; note: string };
export type Verification = { status: Status; checks: CitationCheck[] };

const resolve = (entry: Entry, path: string) =>
  isAbsolute(path) ? path : join(entry.store.root ?? process.cwd(), path);

function onPath(command: string): boolean {
  if (command.includes("/")) return existsSync(command);
  for (const dir of (process.env.PATH ?? "").split(delimiter)) {
    if (!dir) continue;
    try {
      accessSync(join(dir, command), constants.X_OK);
      return true;
    } catch {
      // keep looking
    }
  }
  return false;
}

function findSession(value: string): string | undefined {
  const root = join(getAgentDir(), "sessions");
  if (existsSync(value)) return value;
  try {
    const found = execFileSync(
      "find",
      [root, "-maxdepth", "3", "-name", `${value.replace(/[^\w.-]/g, "")}*`],
      {
        encoding: "utf8",
        timeout: 3_000,
        stdio: ["ignore", "pipe", "ignore"],
      },
    ).trim();
    return found.split("\n")[0] || undefined;
  } catch {
    return undefined;
  }
}

function check(citation: Citation, entry: Entry): CitationCheck {
  const { kind, value } = citation;
  switch (kind) {
    case "path": {
      const path = resolve(entry, value);
      return existsSync(path)
        ? { citation, status: "verified", note: value }
        : { citation, status: "stale", note: `${value} is gone` };
    }
    case "symbol": {
      const search = citation.path
        ? resolve(entry, citation.path)
        : (entry.store.root ?? process.cwd());
      try {
        const hits = execFileSync("git", ["grep", "-l", "-w", "--", value, search], {
          encoding: "utf8",
          timeout: 4_000,
          stdio: ["ignore", "pipe", "ignore"],
        }).trim();
        const count = hits ? hits.split("\n").length : 0;
        return count > 0
          ? {
              citation,
              status: "verified",
              note: `${value} in ${count} file${count === 1 ? "" : "s"}`,
            }
          : { citation, status: "stale", note: `${value} matches nothing in the tree` };
      } catch {
        return { citation, status: "stale", note: `${value} matches nothing in the tree` };
      }
    }
    case "snippet": {
      if (!citation.path) return { citation, status: "unverified", note: "snippet without a path" };
      const path = resolve(entry, citation.path);
      if (!existsSync(path)) return { citation, status: "stale", note: `${citation.path} is gone` };
      try {
        return readFileSync(path, "utf8").includes(value)
          ? { citation, status: "verified", note: citation.path }
          : { citation, status: "stale", note: `${citation.path} no longer contains this text` };
      } catch {
        return { citation, status: "unverified", note: `${citation.path} is unreadable` };
      }
    }
    case "command": {
      const word = value.trim().split(/\s+/)[0] ?? "";
      if (!word || /[|&;<>$`*?]/.test(word))
        return { citation, status: "unverified", note: "not a single command" };
      return onPath(word)
        ? { citation, status: "verified", note: `${word} is installed` }
        : { citation, status: "stale", note: `${word} is not on PATH` };
    }
    case "session": {
      const found = findSession(value);
      return found
        ? { citation, status: "verified", note: "session transcript exists" }
        : { citation, status: "unverified", note: "session transcript not found" };
    }
    case "url": {
      try {
        new URL(value);
        return { citation, status: "unverified", note: "url not fetched" };
      } catch {
        return { citation, status: "stale", note: "not a valid url" };
      }
    }
    case "quote":
      return { citation, status: "unverified", note: "user quote, not machine-checkable" };
  }
}

/** Checks every citation of `entry`; any stale one makes the entry stale. */
export function verify(entry: Entry): Verification {
  const checks = entry.citations.map((citation) => check(citation, entry));
  const status: Status = checks.some((c) => c.status === "stale")
    ? "stale"
    : checks.some((c) => c.status === "verified")
      ? "verified"
      : "unverified";
  return { status, checks };
}
