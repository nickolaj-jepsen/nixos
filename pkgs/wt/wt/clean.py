"""wt clean: remove the folders of open worktrees that hold no uncommitted work.

Committed work is safe on the branch whatever its state, so the only thing that keeps a folder is
what is not committed yet. Removing goes through `close`, so a branch whose commits are all in the
default branch, or whose pull request merged at its tip, goes too and every other branch stays.
The picker starts with exactly those worktrees ticked: closing them leaves nothing behind.
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass

from .commands import close_entry, format_age
from .gh import pr_merged
from .git import ProbeError, info, is_within, probe
from .repo import Located, Repo, RepoLock, current_repo, discover_common, repos_under_root
from .worktrees import Entry, Row, dirty, entries, inspect_row, read_only_git, resolve

UNKNOWN = "?"


@dataclass
class Candidate:
    repo: Repo
    entry: Entry
    row: Row
    subject: str
    # Why closing it leaves nothing behind (its commits are in the default branch, or its PR
    # merged); empty when its branch still holds work the default branch lacks.
    finished: str = ""


def _subject(path: str) -> str:
    try:
        return probe(path, "log", "-1", "--format=%s", "HEAD", "--").strip()
    except ProbeError:
        return ""


def _finished(repo: Repo, entry: Entry, row: Row) -> str:
    """Why closing `entry` loses nothing, judged as `close` judges when it deletes the branch."""
    if row.landed:
        return f"its commits are in {repo.default}"
    if entry.branch and row.landed is False:
        try:
            sha = probe(entry.path or "", "rev-parse", "HEAD").strip()
        except ProbeError:
            return ""
        if pr_merged(repo, entry.branch, sha):
            return "its pull request merged"
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
                    found.append(Candidate(repo, entry, row, _subject(path), _finished(repo, entry, row)))
    return found, left


def _counts(row: Row) -> str:
    ahead = UNKNOWN if row.ahead is None else str(row.ahead)
    behind = UNKNOWN if row.behind is None else str(row.behind)
    return f"+{ahead} -{behind}"


def _changed(row: Row) -> str:
    return UNKNOWN if row.idle_seconds is None else f"{format_age(row.idle_seconds)} ago"


def _after(candidate: Candidate) -> str:
    """What becomes of the branch when the folder goes."""
    if not candidate.entry.branch:
        return "-"
    return "deleted" if candidate.finished else "kept"


def _cells(candidate: Candidate, with_repo: bool) -> list[str]:
    row = candidate.row
    cells = [candidate.repo.key] if with_repo else []
    return [
        *cells,
        row.name,
        row.branch or "(detached)",
        _counts(row),
        _after(candidate),
        _changed(row),
        candidate.subject,
    ]


def _table(candidates: list[Candidate], with_repo: bool) -> list[str]:
    header = (["REPO"] if with_repo else []) + ["NAME", "BRANCH", "COMMITS", "BRANCH AFTER", "CHANGED", "LAST COMMIT"]
    rows = [header, *(_cells(c, with_repo) for c in candidates)]
    widths = [max(len(row[i]) for row in rows) for i in range(len(header))]
    return ["  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip() for row in rows]


# The commits shown under the highlighted row before the rest are only counted.
_SHOWN = 8

INSTRUCTION = "(space ticks, a ticks all, i inverts, enter closes the ticked folders)"


def _describe(candidate: Candidate) -> str:
    """What closing the highlighted worktree leaves behind: the commits its branch holds that the default lacks."""
    if candidate.finished:
        return f"nothing is left behind, {candidate.finished}"
    base, count = candidate.repo.default, candidate.row.ahead
    try:
        out = probe(
            candidate.entry.path or "", "log", f"--max-count={_SHOWN}",
            "--format=%h %s (%cr)", f"{base}..HEAD", "--",
        )
    except ProbeError:
        return ""
    lines = [f"    {line}" for line in out.splitlines()]
    if count is not None and count > _SHOWN:
        lines.append(f"    ... and {count - _SHOWN} more")
    heading = f"{count if count is not None else UNKNOWN} commit(s) not in {base}, which stay on the branch:"
    return "\n".join([heading, *lines])


def pick(candidates: list[Candidate], with_repo: bool) -> list[Candidate]:
    """The candidates ticked in a checklist, those that close with nothing left behind ticked to start; none when cancelled."""
    import questionary

    table = _table(candidates, with_repo)
    # The pointer and tick take two columns the rows do not: indent the header to line up.
    choices: list[questionary.Choice] = [questionary.Separator(f"  {table[0]}")]
    choices += [
        questionary.Choice(text, value=i, checked=bool(c.finished), description=_describe(c))
        for i, (c, text) in enumerate(zip(candidates, table[1:]))
    ]
    chosen = questionary.checkbox(
        "Close which worktrees?",
        choices=choices,
        instruction=INSTRUCTION,
        style=questionary.Style([("separator", "bold")]),
    ).ask()
    return [] if chosen is None else [candidates[i] for i in sorted(chosen)]


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
