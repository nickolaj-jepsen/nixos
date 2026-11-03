"""The lifecycle verbs: new, close, drop, list, cd."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Optional

from .git import die, git, git_ok, info, is_within, run
from .procs import busy_pids, describe_pid
from .repo import Repo, RepoLock, current_repo, repos_under_root
from .worktrees import (
    WIP_TRAILER,
    Entry,
    ahead,
    branch_exists,
    clear_record,
    conflicted,
    dir_name,
    dirty,
    entries,
    idle_seconds,
    is_wip,
    landed,
    operation_in_progress,
    records,
    resolve,
    set_record,
)

STATUS_VERSION = 2
# How long a `close --when-free` waits for the folder to empty before it leaves it be.
WHEN_FREE_TIMEOUT = float(os.environ.get("WT_WHEN_FREE_TIMEOUT") or 3600)
WHEN_FREE_POLL = 1.0


# ---------------------------------------------------------------------------
# new


def copy_worktreeinclude(repo: Repo, dest: str) -> None:
    """Copy the primary checkout's gitignored paths listed in `.worktreeinclude` into `dest`."""
    include = os.path.join(repo.main, ".worktreeinclude")
    if not os.path.isfile(include):
        return
    proc = run(
        ["git", "-C", repo.main, "ls-files", "-z", "--others", "--ignored", "--directory", f"--exclude-from={include}"],
        check=False,
    )
    for rel in proc.stdout.split("\0"):
        rel = rel.rstrip("/")
        if not rel or run(["git", "-C", repo.main, "check-ignore", "-q", "--", rel], check=False).returncode != 0:
            continue
        target = os.path.join(dest, rel)
        if os.path.lexists(target):
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        run(["cp", "-a", "--", os.path.join(repo.main, rel), target], check=False)


def refresh_origin_default(repo: Repo) -> None:
    """Fetch origin's default branch when the last fetch is over a day old; quiet on failure."""
    if run(["git", "--git-dir", repo.common, "remote", "get-url", "origin"], check=False).returncode != 0:
        return
    ref = f"refs/remotes/origin/{repo.default}"
    if git_ok(repo.main, "rev-parse", "--verify", "--quiet", ref):
        try:
            fetched = os.stat(os.path.join(repo.common, "FETCH_HEAD")).st_mtime
        except OSError:
            fetched = 0
        if time.time() - fetched <= 86400:
            return
    proc = run(["timeout", "5", "git", "-C", repo.main, "fetch", "--quiet", "origin", repo.default], check=False)
    if proc.returncode != 0:
        info(f"fetch of origin/{repo.default} failed; basing on the local ref")


def _base(repo: Repo, base: Optional[str]) -> str:
    if base:
        if not git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}"):
            die(f"base ref '{base}' not found")
        return base
    refresh_origin_default(repo)
    for ref in (f"origin/{repo.default}", repo.default):
        if git_ok(repo.main, "rev-parse", "--verify", "--quiet", ref):
            return ref
    die(f"no base: neither origin/{repo.default} nor {repo.default} exists")


def cmd_new(args: argparse.Namespace) -> None:
    repo = current_repo()
    with RepoLock(repo):
        name = dir_name(args.name)
        known = {entry.name: entry for entry in entries(repo)}
        entry = known.get(name)
        if entry and entry.open:
            if args.base:
                die(f"'{name}' is already open at {entry.path}; a base applies only to a new branch")
            print(entry.path)
            return
        path = os.path.join(repo.directory, name)
        if os.path.exists(path):
            die(f"'{path}' exists but is not a worktree; move it away first")
        branch = entry.branch if entry else args.name
        if branch_exists(repo, branch):
            if args.base:
                die(f"branch '{branch}' already exists; a base applies only to a new branch")
            info(f"reopening '{name}' on {branch}")
            run(["git", "-C", repo.main, "worktree", "add", "--quiet", path, branch])
            if is_wip(path, "HEAD"):
                # The changes `close` committed come back as they were left, unstaged.
                run(["git", "-C", path, "reset", "--quiet", "--mixed", "HEAD~"])
                info("restored the uncommitted changes it was closed with")
        else:
            base = _base(repo, args.base)
            info(f"creating '{name}' on new branch {branch} off {base}")
            run(["git", "-C", repo.main, "worktree", "add", "--quiet", "--no-track", "-b", branch, path, base])
        set_record(repo, name, branch)
        copy_worktreeinclude(repo, path)
        print(path)


# ---------------------------------------------------------------------------
# close


def occupants(path: str) -> list[int]:
    """Live processes with their cwd inside `path`, this one's ancestors included: removing it strands them."""
    return busy_pids(path, ignore_ancestors=False)


def _commit_wip(path: str, name: str) -> None:
    run(["git", "-C", path, "add", "--all"])
    # Signing could prompt for a key at session exit, and a wip commit never lands anyway.
    proc = run(
        ["git", "-C", path, "-c", "commit.gpgsign=false", "commit", "--quiet", "--no-verify",
         "-m", f"wip: {name}", "-m", WIP_TRAILER],
        check=False,
    )
    if proc.returncode != 0:
        die(f"could not commit the uncommitted changes in {path}; nothing was removed: {proc.stderr.strip()}")


def _check_closable(repo: Repo, entry: Entry) -> None:
    """Refuse what closing would lose or bury; the folder is untouched when this dies."""
    path = entry.path or ""
    if entry.locked:
        die(f"'{entry.name}' is locked. Run: git -C '{repo.main}' worktree unlock '{path}'")
    operation = operation_in_progress(path)
    if operation:
        die(f"'{entry.name}' is in the middle of a {operation}; finish or abort it in {path}, then close")
    if conflicted(path):
        die(f"'{entry.name}' has unresolved conflicts; resolve them in {path}, then close")
    if not entry.branch:
        if dirty(path):
            die(f"'{entry.name}' is detached with uncommitted changes; put them on a branch first")
        if not git(path, "branch", "--contains", "HEAD", "--format=%(refname)", check=False).strip():
            die(f"'{entry.name}' is detached at a commit no branch has; put it on a branch first")


def settle_branches(repo: Repo, name: str, branches: list[str]) -> None:
    """Delete each of `branches` whose work is in the default branch; forget `name` when its branch goes."""
    record = records(repo).get(name)
    for branch in branches:
        if not branch_exists(repo, branch) or branch == repo.default or not landed(repo, branch):
            continue
        run(["git", "-C", repo.main, "branch", "--quiet", "-D", branch])
        info(f"deleted {branch}: its commits are in {repo.default}")
    if record and not branch_exists(repo, record):
        clear_record(repo, name)


def close_entry(repo: Repo, entry: Entry) -> None:
    """Commit what is uncommitted, remove the folder, and drop the branch when nothing of it is unlanded.

    The caller holds the repo lock and has checked that nothing works inside the folder.
    """
    path = entry.path or ""
    _check_closable(repo, entry)
    if dirty(path):
        _commit_wip(path, entry.name)
        info(f"committed the uncommitted changes in '{entry.name}' as a wip commit")
    if entry.branch:
        set_record(repo, entry.name, entry.branch)
    run(["git", "-C", repo.main, "worktree", "remove", "--force", path])
    run(["git", "-C", repo.main, "worktree", "prune"], check=False)
    info(f"closed {entry.name}")
    settle_branches(repo, entry.name, [entry.branch] if entry.branch else [])
    if branch_exists(repo, entry.branch):
        info(f"{entry.branch} keeps {ahead(repo, entry.branch)} commit(s) not in {repo.default}; 'wt new {entry.name}' reopens it")


def _detach() -> bool:
    """Fork into a background process with no terminal; True in the original process, which should return."""
    pid = os.fork()
    if pid:
        os.waitpid(pid, 0)
        return True
    os.setsid()
    if os.fork():
        os._exit(0)
    null = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(null, fd)
    os.chdir("/")
    return False


def _close_when_free(repo: Repo, entry: Entry) -> None:
    path = entry.path or ""
    info(f"closing {entry.name} once nothing works in it")
    sys.stdout.flush()
    sys.stderr.flush()
    if _detach():
        return
    deadline = time.monotonic() + WHEN_FREE_TIMEOUT
    try:
        while time.monotonic() < deadline:
            if not os.path.isdir(path):
                break
            if not occupants(path):
                with RepoLock(repo):
                    current = next((e for e in entries(repo) if e.path == path), None)
                    if current and not occupants(path):
                        close_entry(repo, current)
                break
            time.sleep(WHEN_FREE_POLL)
    finally:
        os._exit(0)


def cmd_close(args: argparse.Namespace) -> None:
    # A path names its own repository, so a hook can close without standing in a checkout.
    target = args.target or "."
    repo = current_repo(target if os.path.isabs(target) and os.path.isdir(target) else None)
    with RepoLock(repo):
        entry = resolve(repo, target)
        if not entry.open:
            info(f"'{entry.name}' is already closed")
            return
        _check_closable(repo, entry)
        if not args.when_free:
            path = entry.path or ""
            if is_within(os.getcwd(), os.path.realpath(path)):
                die(f"you are inside '{entry.name}'; cd out of it first, or pass --when-free to close it once you leave")
            busy = occupants(path)
            if busy:
                die(f"'{entry.name}' is in use by {describe_pid(busy[0])}; pass --when-free to close it once that exits")
            close_entry(repo, entry)
            return
    _close_when_free(repo, entry)


# ---------------------------------------------------------------------------
# drop


def cmd_drop(args: argparse.Namespace) -> None:
    repo = current_repo()
    with RepoLock(repo):
        entry = resolve(repo, args.name)
        if entry.open:
            path = entry.path or ""
            if is_within(os.getcwd(), os.path.realpath(path)):
                die(f"you are inside '{entry.name}'; cd out of it first")
            busy = occupants(path)
            if busy:
                die(f"'{entry.name}' is in use by {describe_pid(busy[0])}; close that first")
            _check_closable(repo, entry)
            if dirty(path):
                _commit_wip(path, entry.name)
            run(["git", "-C", repo.main, "worktree", "remove", "--force", path])
            run(["git", "-C", repo.main, "worktree", "prune"], check=False)
        clear_record(repo, entry.name)
        if not entry.branch or entry.branch == repo.default:
            info(f"dropped {entry.name}")
            return
        sha = git(repo.main, "rev-parse", f"refs/heads/{entry.branch}").strip()
        run(["git", "-C", repo.main, "branch", "--quiet", "-D", entry.branch])
        info(f"dropped {entry.branch} at {sha}; restore with: git branch {entry.branch} {sha}")


# ---------------------------------------------------------------------------
# list and cd


def _row(repo: Repo, entry: Entry) -> dict:
    is_dirty = bool(entry.path) and dirty(entry.path or "")
    return {
        "name": entry.name,
        "branch": entry.branch,
        "path": entry.path,
        "open": entry.open,
        "ahead": ahead(repo, entry.branch) if entry.branch else 0,
        "landed": bool(entry.branch) and landed(repo, entry.branch),
        "dirty": is_dirty,
        "wip": bool(entry.branch) and is_wip(repo.main, entry.branch),
        "busy": bool(entry.path) and bool(busy_pids(entry.path or "")),
        "idleSeconds": idle_seconds(repo, entry),
    }


def format_age(seconds: int) -> str:
    for size, unit in ((2592000, "mo"), (86400, "d"), (3600, "h"), (60, "m")):
        if seconds >= size:
            return f"{seconds // size}{unit}"
    return f"{seconds}s"


def _table(rows: list[list[str]]) -> str:
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    return "\n".join("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip() for row in rows)


def cmd_list(args: argparse.Namespace) -> None:
    if args.all and args.target:
        die("--all lists every repository; drop it to narrow to one worktree")
    if args.all:
        selected = [(repo, entries(repo)) for repo in repos_under_root()]
    else:
        repo = current_repo()
        selected = [(repo, [resolve(repo, args.target)] if args.target else entries(repo))]
    if args.name:
        for _, found in selected:
            for entry in found:
                print(entry.name)
        return
    documents = [
        {
            "name": repo.key,
            "main": repo.main,
            "defaultBranch": repo.default,
            "worktrees": [_row(repo, entry) for entry in found],
        }
        for repo, found in selected
    ]
    if args.json:
        print(json.dumps({"version": STATUS_VERSION, "repos": documents}, indent=2))
        return
    blocks = []
    for document in documents:
        if not document["worktrees"]:
            continue
        rows = [["NAME", "BRANCH", "FOLDER", "AHEAD", "DIRTY", "IDLE"]]
        for row in document["worktrees"]:
            state = "yes" if row["dirty"] else "wip" if row["wip"] else "-"
            rows.append([row["name"], row["branch"] or "(detached)", "open" if row["open"] else "closed",
                         "landed" if row["landed"] else str(row["ahead"]), state, format_age(row["idleSeconds"])])
        table = _table(rows)
        blocks.append(f"{document['name']}  ({document['main']})\n{table}" if args.all else table)
    if not blocks:
        info("no worktrees")
        return
    print("\n\n".join(blocks))


def cmd_cd(args: argparse.Namespace) -> None:
    repo = current_repo()
    if args.main:
        print(repo.main)
        return
    if not args.target:
        die("name a worktree, or pass --main")
    entry = resolve(repo, args.target)
    if not entry.open:
        die(f"'{entry.name}' is closed; 'wt new {entry.name}' reopens it")
    print(entry.path)
