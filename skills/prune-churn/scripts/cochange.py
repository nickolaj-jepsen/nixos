#!/usr/bin/env python3
"""Rank files by how often they change only because something elsewhere changed.

A commit counts as a tag-along for file F when F changed but no other file in the
commit shares F's directory or name stem; i.e. F was edited to keep up with a change
somewhere else. Tests and docs with high tag-along counts are churn magnets, as are
hub files (registries, barrels, inventory READMEs).

History is always scanned whole; PATHSPEC and --branch only filter which files are
ranked, so co-changes outside the filter still count.

Usage: cochange.py [-n COMMITS] [--branch BASE] [--max-files N] [--top N] [PATHSPEC...]
Prints a TSV: tag_along, commits, spread (distinct other dirs it co-changed with), kind, path.
"""

import argparse
import fnmatch
import os.path
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import PurePosixPath

LOCKFILES = re.compile(
    r"(^|/)(flake\.lock|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|uv\.lock|poetry\.lock"
    r"|Cargo\.lock|go\.sum|Gemfile\.lock|composer\.lock|bun\.lockb?)$"
)
TEST = re.compile(r"(^|/)(tests?|__tests__|spec|e2e)/|[._-](test|spec)\.|(^|/)test_")
SNAPSHOT = re.compile(r"__snapshots__/|\.snap$|(^|/)(golden|testdata|fixtures)/")
AGENT = re.compile(r"(^|/)(AGENTS|CLAUDE|GEMINI)\.md$|(^|/)\.cursor(rules$|/)|copilot-instructions\.md$")
DOC = re.compile(r"\.(md|mdx|rst|adoc)$")
# Stems shared by unrelated files in different dirs (default.nix, index.ts, SKILL.md, ...).
GENERIC = {"index", "default", "__init__", "mod", "main", "lib", "readme", "skill", "host", "types", "utils", "config", "package"}


def kind(path):
    for name, rx in (("snapshot", SNAPSHOT), ("agent", AGENT), ("test", TEST), ("doc", DOC)):
        if rx.search(path):
            return name
    return "code"


def stem(path):
    s = PurePosixPath(path).name.split(".")[0].lower()
    return re.sub(r"^test_|_test$|_spec$", "", s)


def related(a, b):
    if PurePosixPath(a).parent == PurePosixPath(b).parent:
        return True
    sa, sb = stem(a), stem(b)
    if sa in GENERIC or sb in GENERIC or min(len(sa), len(sb)) < 3:
        return False
    word = r"(^|[_\-]){}($|[_\-])"
    return bool(re.search(word.format(re.escape(sa)), sb) or re.search(word.format(re.escape(sb)), sa))


def git(*args):
    proc = subprocess.run(["git", "-c", "core.quotePath=false", *args], capture_output=True, text=True)
    if proc.returncode:
        sys.exit(f"git {' '.join(args)}: {proc.stderr.strip()}")
    return proc.stdout


def commits(n, max_files):
    out = git("log", "--no-merges", "--name-only", f"-n{n}", "--format=%x00")
    for block in out.split("\0"):
        files = [f for f in block.split("\n") if f and not LOCKFILES.search(f)]
        if files and len(files) <= max_files:
            yield files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=300, help="commits of history to scan")
    ap.add_argument("--branch", metavar="BASE", help="rank only files changed in BASE...HEAD")
    ap.add_argument("--max-files", type=int, default=20, help="skip bulk commits touching more files")
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("pathspec", nargs="*", help="rank only files under these paths or globs")
    args = ap.parse_args()

    total, tag, spread = defaultdict(int), defaultdict(int), defaultdict(set)
    sizes = []
    for files in commits(args.n, args.max_files):
        sizes.append(len(files))
        for f in files:
            others = [o for o in files if o != f]
            total[f] += 1
            if others and not any(related(f, o) for o in others):
                tag[f] += 1
                spread[f].update(str(PurePosixPath(o).parent) for o in others)

    # git paths are repo-root-relative; accept paths relative to the cwd too.
    prefix = git("rev-parse", "--show-prefix").strip()
    specs = [os.path.normpath(os.path.join(prefix, p)) for p in args.pathspec]

    def wanted(f):
        return not specs or any(f == p or f.startswith(p + "/") or fnmatch.fnmatch(f, p) for p in specs)

    focus = set(git("diff", "--name-only", f"{args.branch}...HEAD").splitlines()) if args.branch else None
    ranked = sorted(
        (f for f in tag if tag[f] > 1 and wanted(f) and (focus is None or f in focus)),
        key=lambda f: (tag[f], len(spread[f])),
        reverse=True,
    )
    if sizes:
        print(f"# {len(sizes)} commits, mean {sum(sizes) / len(sizes):.1f} files/commit")
    print("tag_along\tcommits\tspread\tkind\tpath")
    for f in ranked[: args.top]:
        print(f"{tag[f]}\t{total[f]}\t{len(spread[f])}\t{kind(f)}\t{f}")


if __name__ == "__main__":
    main()
