"""wt clean: remove the folders of open worktrees that hold no uncommitted work.

Committed work is safe on the branch whatever its state, so the only thing that keeps a folder is
what is not committed yet. Removing goes through `close`, so a
branch whose commits are all in the default branch goes too and every other branch stays.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass

from .commands import close_entry, format_age
from .git import ProbeError, die, info, is_within, probe
from .repo import Located, Repo, RepoLock, current_repo, discover_common, repos_under_root
from .worktrees import Entry, Row, dirty, entries, inspect_row, read_only_git, resolve

UNKNOWN = "?"


@dataclass
class Candidate:
    repo: Repo
    entry: Entry
    row: Row
    subject: str


def _subject(path: str) -> str:
    try:
        return probe(path, "log", "-1", "--format=%s", "HEAD", "--").strip()
    except ProbeError:
        return ""


def everywhere(args: argparse.Namespace) -> bool:
    """Whether clean covers every repository under the root: asked to, or outside any repository."""
    return args.all or discover_common(os.getcwd()) is None


def gather(args: argparse.Namespace) -> tuple[list[Candidate], list[str]]:
    """The worktrees clean may remove, and a line for each it leaves and why."""
    found: list[Candidate] = []
    left: list[str] = []
    cwd = os.path.realpath(os.getcwd())
    every = everywhere(args)
    with read_only_git():
        if every:
            scope = repos_under_root()
        else:
            here = current_repo(create=False)
            scope = [Located(name=here.key, repo=here)]
        for item in scope:
            repo = item.repo
            if repo is None:
                left.append(f"{item.name}: {item.error}")
                continue
            try:
                selected = entries(repo)
            except ProbeError as error:
                left.append(f"{repo.key}: {error}")
                continue
            for entry in selected:
                if not entry.open:
                    continue
                label = f"{repo.key}/{entry.name}" if every else entry.name
                path = entry.path or ""
                if entry.locked:
                    left.append(f"{label}: locked")
                    continue
                if is_within(cwd, os.path.realpath(path)):
                    left.append(f"{label}: you are in it")
                    continue
                row = inspect_row(repo, entry)
                if row.dirty is None:
                    left.append(f"{label}: could not tell whether it has uncommitted changes: {row.error}")
                elif row.dirty:
                    left.append(f"{label}: uncommitted changes")
                else:
                    found.append(Candidate(repo, entry, row, _subject(path)))
    return found, left


def _counts(row: Row) -> str:
    ahead = UNKNOWN if row.ahead is None else str(row.ahead)
    behind = UNKNOWN if row.behind is None else str(row.behind)
    return f"+{ahead} -{behind}"


def _changed(row: Row) -> str:
    return UNKNOWN if row.idle_seconds is None else f"{format_age(row.idle_seconds)} ago"


def _cells(candidate: Candidate, with_repo: bool) -> list[str]:
    row = candidate.row
    cells = [candidate.repo.key] if with_repo else []
    return [
        *cells,
        row.name,
        row.branch or "(detached)",
        _counts(row),
        _changed(row),
        candidate.subject,
    ]


def _table(candidates: list[Candidate], with_repo: bool) -> list[str]:
    header = (["REPO"] if with_repo else []) + ["NAME", "BRANCH", "COMMITS", "CHANGED", "LAST COMMIT"]
    rows = [header, *(_cells(c, with_repo) for c in candidates)]
    widths = [max(len(row[i]) for row in rows) for i in range(len(header))]
    return ["  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip() for row in rows]


# A preview of what the folder's branch holds: the commits not in the default branch, then the tip.
_PREVIEW = (
    'path=$1; base=$2; '
    'printf "\\033[1mnot in %s\\033[0m\\n" "$base"; '
    'if [ "$(git -C "$path" rev-list --count "$base..HEAD" --)" = 0 ]; '
    'then echo "nothing: the branch goes with the folder"; '
    'else git -C "$path" log --color=always --format="%C(yellow)%h%C(reset) %s %C(dim)%cr%C(reset)" "$base..HEAD" --; fi; '
    'printf "\\n\\033[1mlast commit\\033[0m\\n"; '
    'git -C "$path" log --color=always -1 --stat --format="%C(yellow)%h%C(reset) %s%n%C(dim)%an, %cr%C(reset)" HEAD --'
)


def pick(candidates: list[Candidate], with_repo: bool) -> list[Candidate]:
    """The candidates chosen in fzf; none when it is cancelled."""
    table = _table(candidates, with_repo)
    lines = [f"{i}\t{c.entry.path}\t{c.repo.default}\t{text}" for i, (c, text) in enumerate(zip(candidates, table[1:]))]
    preview = f"sh -c '{_PREVIEW}' _ {{2}} {{3}}"
    proc = subprocess.run(
        [
            "fzf", "--multi", "--ansi", "--reverse", "--no-sort",
            "--delimiter=\t", "--with-nth=4..",
            "--header", f"{table[0]}\ntab select · ctrl-a all · enter removes the folders; a branch at +0 goes too, the rest stay",
            "--bind", "ctrl-a:toggle-all",
            "--preview", preview, "--preview-window", "down,50%,wrap",
            "--prompt", "clean> ",
        ],
        input="\n".join(lines) + "\n",
        stdout=subprocess.PIPE,
        text=True,
        # fzf runs the preview with $SHELL, which may not speak sh.
        env={**os.environ, "SHELL": "/bin/sh"},
    )
    if proc.returncode != 0:
        return []
    chosen = {int(line.split("\t", 1)[0]) for line in proc.stdout.splitlines() if line}
    return [c for i, c in enumerate(candidates) if i in chosen]


def remove(candidates: list[Candidate]) -> int:
    """Close each chosen worktree, checking again under the lock; the number it left open."""
    failed = 0
    for candidate in candidates:
        repo, name = candidate.repo, candidate.entry.name
        try:
            with RepoLock(repo):
                entry = resolve(repo, name)
                path = entry.path or ""
                if not entry.open:
                    continue
                if dirty(path):
                    info(f"left {name}: it has uncommitted changes now")
                    failed += 1
                    continue
                close_entry(repo, entry)
        except ProbeError as error:
            info(f"left {name}: {error}")
            failed += 1
        except SystemExit:
            # die() already said why; one worktree that refuses must not stop the rest.
            failed += 1
    return failed


def cmd_clean(args: argparse.Namespace) -> None:
    candidates, left = gather(args)
    with_repo = everywhere(args)
    for line in left:
        info(f"left {line}")
    if not candidates:
        info("nothing to clean")
        return
    interactive = sys.stdin.isatty() and sys.stdout.isatty()
    if args.yes:
        chosen = candidates
    elif not args.dry_run and interactive:
        if not shutil.which("fzf"):
            die("the picker needs fzf; pass --yes to remove every folder listed by --dry-run")
        chosen = pick(candidates, with_repo)
        if not chosen:
            info("nothing removed")
            return
    else:
        print("\n".join(_table(candidates, with_repo)))
        if not args.dry_run:
            info("nothing removed: pass --yes to remove these folders, or run it in a terminal to pick")
        return
    if remove(chosen):
        raise SystemExit(1)
