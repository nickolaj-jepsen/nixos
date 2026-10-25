"""Terminal presentation: tables, pickers and row formatting."""

from __future__ import annotations

import shutil
import subprocess
import sys
from typing import TYPE_CHECKING

from .git import die

if TYPE_CHECKING:
    from .repo import Repo
    from .status import Worktree


def format_age(seconds: int) -> str:
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    if seconds < 2592000:
        return f"{seconds // 86400}d"
    return f"{seconds // 2592000}mo"


def _table(rows: list[list[str]], headers: list[str]) -> str:
    widths = [len(h) for h in headers]
    for row in rows:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))
    lines = [
        "  ".join(headers[i].ljust(widths[i]) for i in range(len(headers))).rstrip(),
        *(
            "  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip()
            for row in rows
        ),
    ]
    return "\n".join(lines)


def pick(repo: Repo, prompt: str, rows: list[Worktree]) -> Worktree:
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        die("no worktree named; pass a name or '.'")
    if not shutil.which("fzf"):
        die("fzf not found on PATH; pass a worktree name")
    headers = ["NAME", "BRANCH", "STATE", "vs main", "LANDED", "ACTIVITY"]
    body = [
        [row.name, row.branch or ("(main)" if row.is_main else "(detached)"), _state_cell(row),
         _vs_cell(row), _landed_cell(row), format_age(row.idle_seconds)]
        for row in rows
    ]
    table = _table(body, headers)
    proc = subprocess.run(
        ["fzf", "--prompt", f"{prompt} > ", "--header-lines=1", "--layout=reverse", "--height=40%"],
        input=table + "\n",
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        die("no selection")
    name = proc.stdout.split()[0]
    for row in rows:
        if row.name == name:
            return row
    die(f"no worktree named '{name}'")


# ---------------------------------------------------------------------------
# Human display


def _state_cell(row: Worktree) -> str:
    parts = [row.state]
    if row.locked:
        parts.append("locked")
    if row.busy:
        parts.append("busy")
    return "/".join(parts)


def _vs_cell(row: Worktree) -> str:
    if row.is_main:
        return "(main)"
    if not row.registered:
        return "-"
    if row.ahead is None or row.behind is None:
        return "-"
    return f"+{row.ahead} -{row.behind}"


def _landed_cell(row: Worktree) -> str:
    if row.is_main:
        return "-"
    if not row.registered:
        return "-"
    return "yes" if row.landed else "no"
