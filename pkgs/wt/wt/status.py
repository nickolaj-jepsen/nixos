"""Worktree state: rows, landed detection, occupancy, JSON and the list verb."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import time
from pathlib import Path
from dataclasses import dataclass
from typing import Iterable, Optional

from .git import die, git, git_ok, info, is_within, run
from .repo import Repo, current_repo, discover_common, registered_worktrees, repos_under_root, worktree_root
from .ui import _landed_cell, _state_cell, _table, _vs_cell, format_age

STATUS_VERSION = 1
SQUASH_HISTORY_LIMIT = 500
# An agent's subagents work in a worktree by path, never by cwd, so occupancy can't see them;
# a branch nothing has moved yet is kept this long instead of passing for landed.
FRESH_GRACE_SECONDS = 24 * 3600


def _ancestors() -> set[int]:
    pids: set[int] = {os.getpid()}
    pid = os.getppid()
    while pid and pid > 1:
        pids.add(pid)
        try:
            stat = Path(f"/proc/{pid}/stat").read_text()
        except OSError:
            break
        rest = stat.rsplit(")", 1)[-1].split()
        pid = int(rest[1]) if len(rest) > 1 else 0
    for extra in (os.environ.get("WT_IGNORE_PIDS") or "").split():
        if extra.isdigit():
            pids.add(int(extra))
    return pids


_PROC_ROWS: Optional[list[tuple[int, str]]] = None
_PROC_ROWS_READ = False


def _proc_cwds() -> Optional[list[tuple[int, str]]]:
    global _PROC_ROWS, _PROC_ROWS_READ
    if _PROC_ROWS_READ:
        return _PROC_ROWS
    _PROC_ROWS_READ = True
    if os.path.isdir("/proc/self"):
        rows: list[tuple[int, str]] = []
        for entry in os.scandir("/proc"):
            if not entry.name.isdigit():
                continue
            try:
                target = os.readlink(os.path.join(entry.path, "cwd"))
            except OSError:
                continue
            rows.append((int(entry.name), target))
        _PROC_ROWS = rows
        return rows
    if shutil.which("lsof"):
        proc = run(["lsof", "-w", "-n", "-d", "cwd", "-F", "pn"], check=False)
        if proc.returncode not in (0, 1):
            return None
        rows = []
        pid = None
        for line in proc.stdout.splitlines():
            if line.startswith("p"):
                pid = int(line[1:]) if line[1:].isdigit() else None
            elif line.startswith("n") and pid:
                rows.append((pid, line[1:]))
        _PROC_ROWS = rows
        return rows
    return None


def busy_pid(path: str) -> Optional[int]:
    root = os.path.realpath(path)
    ours = _ancestors()
    rows = _proc_cwds()
    if rows is None:
        return None
    for pid, cwd in rows:
        if pid in ours or pid == os.getpid():
            continue
        try:
            real = os.path.realpath(cwd)
        except OSError:
            continue
        if is_within(real, root):
            return pid
    return None


def describe_pid(pid: int) -> str:
    """`<command> (pid N)`, or `pid N` when the process name cannot be read."""
    try:
        name = Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        # `ps` is cosmetic here, so a build without one still names the pid.
        try:
            name = run(["ps", "-o", "comm=", "-p", str(pid)], check=False).stdout.strip()
        except OSError:
            name = ""
    return f"{os.path.basename(name)} (pid {pid})" if name else f"pid {pid}"


def _binary_change(path: str, merge_base: str) -> bool:
    numstat = git(path, "diff", "--numstat", f"{merge_base}..HEAD", check=False)
    return any(line.startswith("-\t-") for line in numstat.splitlines())


def branch_landed(repo: Repo, path: str) -> bool:
    default = repo.default
    if not git_ok(path, "rev-parse", "--verify", "--quiet", f"refs/heads/{default}"):
        return False
    if git_ok(path, "merge-base", "--is-ancestor", "HEAD", default):
        return True
    merge_base = git(path, "merge-base", default, "HEAD", check=False).strip()
    # Patch equivalence cannot prove a binary change landed; only ancestry can.
    if merge_base and _binary_change(path, merge_base):
        return False
    cherry = git(path, "cherry", default, "HEAD", check=False)
    lines = [line for line in cherry.splitlines() if line.strip()]
    if lines and all(line.startswith("-") for line in lines):
        return True
    return squash_landed(repo, path)


def fresh_age(path: str, branch: str) -> Optional[int]:
    """Seconds since `branch` was created, while that is under FRESH_GRACE_SECONDS and its reflog
    holds nothing after the creation; None otherwise, including for a detached HEAD or no reflog."""
    if not branch:
        return None
    log = git(path, "reflog", "show", "--date=unix", "--format=%gd", f"refs/heads/{branch}", check=False)
    entries = log.split()
    if len(entries) != 1 or "@{" not in entries[0]:
        return None
    stamp = entries[0].rsplit("@{", 1)[1].rstrip("}")
    if not stamp.isdigit():
        return None
    age = max(0, int(time.time()) - int(stamp))
    return age if age < FRESH_GRACE_SECONDS else None


def held_elsewhere(path: str, branch: str) -> bool:
    """Whether a branch other than `branch`, local or remote, contains HEAD, so dropping `branch` loses no commit.

    A remote branch of the same name doesn't count: a pushed feature branch is still unlanded work.
    """
    refs = git(path, "for-each-ref", "--contains", "HEAD", "--format=%(refname)", "refs/heads", "refs/remotes", check=False)
    for ref in refs.splitlines():
        if ref.endswith("/HEAD") or ref == f"refs/heads/{branch}":
            continue
        if branch and ref.startswith("refs/remotes/") and ref.split("/", 3)[-1] == branch:
            continue
        return True
    return False


def squash_landed(repo: Repo, path: str) -> bool:
    default = repo.default
    merge_base = git(path, "merge-base", default, "HEAD", check=False).strip()
    if not merge_base:
        return False
    count = run(
        ["git", "-C", path, "rev-list", "--count", f"{merge_base}..{default}"], check=False
    )
    if count.returncode != 0:
        return False
    try:
        if int(count.stdout.strip()) > SQUASH_HISTORY_LIMIT:
            return False
    except ValueError:
        return False
    numstat = git(path, "diff", "--numstat", f"{merge_base}..HEAD", check=False)
    if not numstat.strip():
        return False
    if any(line.startswith("-\t-") for line in numstat.splitlines()):
        return False
    try:
        touched = sum(int(line.split("\t", 1)[0]) for line in numstat.splitlines() if line.split("\t", 1)[0].isdigit())
    except ValueError:
        return False
    if touched > 20000:
        return False
    diff = git(path, "diff", f"{merge_base}..HEAD", check=False)
    if not diff.strip():
        return False
    own = run(["git", "patch-id", "--stable"], input_text=diff, check=False)
    if own.returncode != 0 or not own.stdout.strip():
        return False
    own_id = own.stdout.split()[0]
    log = run(
        [
            "git",
            "-C",
            path,
            "log",
            "--first-parent",
            "--patch",
            "--format=commit %H",
            f"{merge_base}..{default}",
        ],
        check=False,
    )
    if log.returncode != 0:
        return False
    ids = run(["git", "patch-id", "--stable"], input_text=log.stdout, check=False)
    if ids.returncode != 0:
        return False
    return any(line.split() and line.split()[0] == own_id for line in ids.stdout.splitlines())


def idle_seconds(path: str) -> int:
    now = int(time.time())
    git_dir = git(path, "rev-parse", "--path-format=absolute", "--git-dir", check=False).strip()
    stamps: list[int] = []
    if git_dir:
        for name in ("HEAD",):
            try:
                stamps.append(int(os.stat(os.path.join(git_dir, name)).st_mtime))
            except OSError:
                pass
    commit = git(path, "log", "-1", "--format=%ct", check=False).strip()
    if commit.isdigit():
        stamps.append(int(commit))
    if not stamps:
        try:
            stamps.append(int(os.stat(path).st_mtime))
        except OSError:
            stamps.append(now)
    return max(0, now - max(stamps))


# ---------------------------------------------------------------------------
# Worktree rows


@dataclass
class Worktree:
    name: str
    path: str
    registered: bool
    branch: str
    detached: bool
    state: str
    ahead: Optional[int]
    behind: Optional[int]
    locked: bool
    busy: bool
    landed: bool
    safe_to_remove: bool
    is_main: bool
    idle_seconds: int

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "path": self.path,
            "registered": self.registered,
            "branch": self.branch,
            "detached": self.detached,
            "state": self.state,
            "ahead": self.ahead,
            "behind": self.behind,
            "locked": self.locked,
            "busy": self.busy,
            "landed": self.landed,
            "safeToRemove": self.safe_to_remove,
            "isMain": self.is_main,
            "idleSeconds": self.idle_seconds,
        }


def _orphan_dirs(repo: Repo) -> list[str]:
    dirs: list[str] = []
    for scan in (repo.directory, os.path.join(repo.main, ".claude", "worktrees")):
        if not os.path.isdir(scan):
            continue
        for entry in sorted(os.scandir(scan), key=lambda e: e.name):
            if not entry.is_dir(follow_symlinks=False):
                continue
            if entry.name.startswith("."):
                continue
            common = discover_common(entry.path)
            if common is not None and common != repo.common:
                continue
            dirs.append(entry.path)
    return dirs


def gather(repo: Repo, *, deep: bool = True) -> list[Worktree]:
    registered = registered_worktrees(repo.common)
    by_path = {item["path"]: item for item in registered}
    paths: list[str] = []
    if repo.main not in by_path:
        paths.append(repo.main)
    paths.extend(item["path"] for item in registered)
    for path in _orphan_dirs(repo):
        if path not in by_path and path not in paths:
            paths.append(path)

    base_counts: dict[str, int] = {}
    for path in paths:
        base_counts[os.path.basename(path)] = base_counts.get(os.path.basename(path), 0) + 1

    rows: list[Worktree] = []
    for path in paths:
        base = os.path.basename(path)
        name = base
        if base_counts.get(base, 0) > 1:
            name = f"{os.path.basename(os.path.dirname(path))}/{base}"
        registered_row = by_path.get(path)
        is_main = path == repo.main
        if registered_row is None:
            has_files = False
            try:
                for root, _dirs, files in os.walk(path):
                    if files:
                        has_files = True
                        break
            except OSError:
                has_files = True
            rows.append(
                Worktree(
                    name=name,
                    path=path,
                    registered=False,
                    branch="",
                    detached=False,
                    state="orphan",
                    ahead=None,
                    behind=None,
                    locked=False,
                    busy=busy_pid(path) is not None if deep else False,
                    landed=False,
                    safe_to_remove=(not has_files and not is_main) if deep else False,
                    is_main=is_main,
                    idle_seconds=idle_seconds(path),
                )
            )
            continue

        branch = registered_row["branch"]
        locked = bool(registered_row["locked"])
        if not deep:
            rows.append(
                Worktree(
                    name=name,
                    path=path,
                    registered=True,
                    branch=branch,
                    detached=not branch,
                    state="",
                    ahead=None,
                    behind=None,
                    locked=locked,
                    busy=False,
                    landed=False,
                    safe_to_remove=False,
                    is_main=is_main,
                    idle_seconds=0,
                )
            )
            continue
        porcelain = git(path, "status", "--porcelain", check=False)
        if not porcelain.strip():
            state = "clean"
        elif any(not line.startswith("??") for line in porcelain.splitlines()):
            state = "dirty"
        else:
            state = "untracked"
        ahead: Optional[int] = None
        behind: Optional[int] = None
        landed = False
        if git_ok(path, "rev-parse", "--verify", "--quiet", f"refs/heads/{repo.default}"):
            counts = git(path, "rev-list", "--left-right", "--count", f"{repo.default}...HEAD", check=False)
            parts = counts.split()
            if len(parts) == 2:
                behind, ahead = int(parts[0]), int(parts[1])
                landed = branch_landed(repo, path)
        busy = busy_pid(path) is not None
        safe = (
            not is_main
            and not locked
            and state == "clean"
            and (landed or held_elsewhere(path, branch))
            and not busy
            and fresh_age(path, branch) is None
        )
        if is_main:
            landed = True
        rows.append(
            Worktree(
                name=name,
                path=path,
                registered=True,
                branch=branch,
                detached=not branch,
                state=state,
                ahead=ahead,
                behind=behind,
                locked=locked,
                busy=busy,
                landed=landed,
                safe_to_remove=safe,
                is_main=is_main,
                idle_seconds=idle_seconds(path),
            )
        )
    return rows


def repo_json(repo: Repo, rows: list[Worktree]) -> dict:
    return {
        "name": repo.key,
        "root": repo.directory,
        "main": repo.main,
        "defaultBranch": repo.default,
        "worktrees": [row.to_json() for row in rows],
    }


def status_document(repos: Iterable[tuple[Repo, list[Worktree]]]) -> dict:
    return {
        "version": STATUS_VERSION,
        "root": worktree_root(),
        "repos": [repo_json(repo, rows) for repo, rows in repos],
    }


def resolve_row(repo: Repo, target: str, rows: Optional[list[Worktree]] = None) -> Worktree:
    rows = rows if rows is not None else gather(repo)
    if target == "." or os.path.isabs(target):
        inside = os.path.realpath(os.getcwd() if target == "." else target)
        # Longest path first, so a worktree nested under the primary checkout wins over it.
        for row in sorted(rows, key=lambda row: len(row.path), reverse=True):
            if is_within(inside, os.path.realpath(row.path)):
                return row
        die(f"{'current directory' if target == '.' else target} is not inside a known worktree")
    matches = [row for row in rows if row.name == target]
    if not matches:
        matches = [row for row in rows if os.path.basename(row.path) == target]
    if not matches:
        matches = [row for row in rows if row.branch == target]
    if not matches:
        die(f"no worktree named '{target}'")
    if len(matches) > 1:
        die(f"worktree name '{target}' is ambiguous; use one of: {', '.join(row.name for row in matches)}")
    return matches[0]


def cmd_list(args: argparse.Namespace) -> None:
    if args.all and args.target:
        die("--all lists every repository; drop it to narrow to one worktree")
    if args.all:
        repos = [(repo, gather(repo)) for repo in repos_under_root()]
    else:
        repo = current_repo()
        rows = gather(repo)
        repos = [(repo, [resolve_row(repo, args.target, rows)] if args.target else rows)]
    if args.json:
        print(json.dumps(status_document(repos), indent=2, sort_keys=False))
        return
    if not repos:
        info("no worktrees")
        return
    blocks: list[str] = []
    for repo, rows in repos:
        body = [
            [row.name, row.branch or ("(main)" if row.is_main else "(detached)"), _state_cell(row),
             _vs_cell(row), _landed_cell(row), format_age(row.idle_seconds)]
            for row in rows
        ]
        headers = ["NAME", "BRANCH", "STATE", "vs main", "LANDED", "ACTIVITY"]
        table = _table(body, headers)
        blocks.append(table if not args.all else f"{repo.key}  ({repo.main})\n{table}")
    print("\n\n".join(blocks))
