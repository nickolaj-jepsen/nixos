"""The lifecycle verbs: new, close, drop, list, cd."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import NoReturn, Optional

from .gh import has_origin, pr_merged, stack_layers
from .git import ProbeError, die, git, git_ok, info, inspect, is_within, normpath, run
from .procs import busy_pids, describe_pid
from .repo import Located, Repo, RepoLock, current_repo, repos_under_root, stale_worktrees
from .worktrees import (
    WIP_TRAILER,
    Entry,
    Row,
    ahead,
    branch_exists,
    branches_containing,
    clear_record,
    conflicted,
    dir_name,
    dirty,
    entries,
    inspect_row,
    is_wip,
    landed,
    layers,
    operation_in_progress,
    read_only_git,
    records,
    resolve,
    set_layers,
    set_record,
)

STATUS_VERSION = 3
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
        if entry and entry.branch and entry.branch != args.name and dir_name(entry.branch) == name:
            # `feat/y` and `feat-y` name one folder: the folder remembers which branch it holds.
            die(
                f"'{name}' holds branch '{entry.branch}', not '{args.name}'; "
                f"both map to the same folder, so name one of them differently"
            )
        if entry and entry.open:
            if args.base:
                die(f"'{name}' is already open at {entry.path}; a base applies only to a new branch")
            print(entry.path)
            return
        path = os.path.join(repo.directory, name)
        if os.path.exists(path):
            die(f"'{path}' exists but is not a worktree; move it away first")
        if entry and not entry.branch:
            # A registration git reported as detached has no branch to recreate the folder from.
            # Pruning it to get past `worktree add` would drop the only record of its commit.
            die(
                f"'{name}' is registered with no branch"
                + (f", detached at {entry.head}" if entry.head else "")
                + f"; 'wt drop {name}' removes it and names the commit, then create it again"
            )
        branch = entry.branch if entry else args.name
        # A deleted folder keeps its registration, which blocks this checkout and the branch delete
        # that follows; prune it so the canonical folder and branch can be used again.
        blocking = [
            item
            for item in stale_worktrees(repo.common)
            if normpath(item["path"]) == path or (branch and item["branch"] == branch)
        ]
        if blocking:
            run(["git", "-C", repo.main, "worktree", "prune"])
        if branch_exists(repo, branch):
            if args.base:
                die(f"branch '{branch}' already exists; a base applies only to a new branch")
            info(f"reopening '{name}' on {branch}")
            run(["git", "-C", repo.main, "worktree", "add", "--quiet", path, branch])
            if inspect(f"'{name}'", lambda: is_wip(path, "HEAD")):
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
    context = f"'{entry.name}'"
    if entry.locked:
        die(f"'{entry.name}' is locked. Run: git -C '{repo.main}' worktree unlock '{path}'")
    operation = inspect(context, lambda: operation_in_progress(path))
    if operation:
        die(f"'{entry.name}' is in the middle of a {operation}; finish or abort it in {path}, then close")
    conflicts = inspect(context, lambda: conflicted(path))
    if conflicts:
        die(f"'{entry.name}' has unresolved conflicts; resolve them in {path}, then close")
    if not entry.branch:
        if inspect(context, lambda: dirty(path)):
            die(f"'{entry.name}' is detached with uncommitted changes; put them on a branch first")
        if not inspect(context, lambda: branches_containing(path, "HEAD")):
            die(f"'{entry.name}' is detached at a commit no branch has; put it on a branch first")


def _finished(repo: Repo, branch: str) -> Optional[str]:
    """Why `branch` can go with nothing lost: its commits are in the default branch, or its PR merged at this tip."""
    if not branch_exists(repo, branch) or branch == repo.default:
        return None
    state = landed(repo, branch)
    if state:
        return f"its commits are in {repo.default}"
    if state is None:
        info(f"could not tell whether {branch} is in {repo.default}; keeping it")
        return None
    sha = git(repo.main, "rev-parse", f"refs/heads/{branch}").strip()
    if pr_merged(repo, branch, sha):
        return "its pull request merged"
    return None


def settle_branches(repo: Repo, name: str, branches: list[str]) -> None:
    """Delete each of `branches` that is finished; forget `name` once none of its branches is left."""
    for branch in branches:
        why = _finished(repo, branch)
        if why:
            run(["git", "-C", repo.main, "branch", "--quiet", "-D", branch])
            info(f"deleted {branch}: {why}")
    record = records(repo).get(name)
    remaining = [branch for branch in [record or "", *layers(repo, name)] if branch_exists(repo, branch)]
    if not remaining:
        clear_record(repo, name)
    elif record and not branch_exists(repo, record):
        # The head went but other layers stay: reopen on the topmost one left.
        set_record(repo, name, remaining[-1])


def prune(repo: Repo) -> None:
    """Delete the branches of closed worktrees that finished since they were closed."""
    open_names = {entry.name for entry in entries(repo) if entry.open}
    for name, head in records(repo).items():
        if name not in open_names:
            settle_branches(repo, name, [*layers(repo, name), head])


def close_entry(repo: Repo, entry: Entry) -> None:
    """Commit what is uncommitted, remove the folder, and drop the branch when nothing of it is unlanded.

    The caller holds the repo lock and has checked that nothing works inside the folder.
    """
    path = entry.path or ""
    _check_closable(repo, entry)
    # Read before the folder goes: `gh stack` answers for the checkout it runs in.
    stacked = [b for b in stack_layers(path) if b != entry.branch] if has_origin(repo) else []
    if inspect(f"'{entry.name}'", lambda: dirty(path)):
        _commit_wip(path, entry.name)
        info(f"committed the uncommitted changes in '{entry.name}' as a wip commit")
    if entry.branch:
        set_record(repo, entry.name, entry.branch)
    set_layers(repo, entry.name, stacked)
    run(["git", "-C", repo.main, "worktree", "remove", "--force", path])
    run(["git", "-C", repo.main, "worktree", "prune"], check=False)
    info(f"closed {entry.name}")
    settle_branches(repo, entry.name, [*stacked, entry.branch] if entry.branch else stacked)
    if branch_exists(repo, entry.branch):
        try:
            info(f"{entry.branch} keeps {ahead(repo, entry.branch)} commit(s) not in {repo.default}; "
                 f"'wt new {entry.name}' reopens it")
        except ProbeError:
            info(f"{entry.branch} is kept; 'wt new {entry.name}' reopens it")
    prune(repo)


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
        stacked = layers(repo, entry.name)
        if entry.open:
            path = entry.path or ""
            if has_origin(repo):
                stacked = stack_layers(path)
            if is_within(os.getcwd(), os.path.realpath(path)):
                die(f"you are inside '{entry.name}'; cd out of it first")
            busy = occupants(path)
            if busy:
                die(f"'{entry.name}' is in use by {describe_pid(busy[0])}; close that first")
            _check_closable(repo, entry)
            if inspect(f"'{entry.name}'", lambda: dirty(path)):
                _commit_wip(path, entry.name)
            run(["git", "-C", repo.main, "worktree", "remove", "--force", path])
            run(["git", "-C", repo.main, "worktree", "prune"], check=False)
        else:
            # Only data that is still somewhere else can be dropped without a recovery point.
            if not entry.branch and entry.head:
                info(f"'{entry.name}' was detached at {entry.head}; restore it with: git switch --detach {entry.head}")
            # A stale registration still claims its branch: pruned, or the branch delete refuses.
            run(["git", "-C", repo.main, "worktree", "prune"], check=False)
        clear_record(repo, entry.name)
        dropped = [b for b in dict.fromkeys([*stacked, entry.branch]) if branch_exists(repo, b) and b != repo.default]
        if not dropped:
            info(f"dropped {entry.name}")
            return
        for branch in dropped:
            sha = git(repo.main, "rev-parse", f"refs/heads/{branch}").strip()
            run(["git", "-C", repo.main, "branch", "--quiet", "-D", branch])
            info(f"dropped {branch} at {sha}; restore with: git branch {branch} {sha}")


# ---------------------------------------------------------------------------
# list and cd


def _row_document(row: Row) -> dict:
    """One listing row in the JSON v3 shape: a value that could not be inspected is null."""
    return {
        "name": row.name,
        "branch": row.branch,
        "path": row.path,
        "open": row.open,
        "ahead": row.ahead,
        "landed": row.landed,
        "dirty": row.dirty,
        "wip": row.wip,
        "busy": row.busy,
        "idleSeconds": row.idle_seconds,
        "error": row.error,
    }


def _repo_document(item: Located, found: list[Row]) -> dict:
    """One repository in the JSON v3 shape; `error` is set when the repository itself failed."""
    return {
        "name": item.name,
        "main": item.repo.main if item.repo else None,
        "defaultBranch": item.repo.default if item.repo else None,
        "error": item.error,
        "worktrees": [_row_document(row) for row in found],
    }


def format_age(seconds: int) -> str:
    for size, unit in ((2592000, "mo"), (86400, "d"), (3600, "h"), (60, "m")):
        if seconds >= size:
            return f"{seconds // size}{unit}"
    return f"{seconds}s"


def _table(rows: list[list[str]]) -> str:
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    return "\n".join("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip() for row in rows)


# What a value a probe could not answer prints as, instead of a clean tree or a zero count.
UNKNOWN = "?"


def _ahead_cell(row: dict) -> str:
    if row["landed"] is None:
        return UNKNOWN
    if row["landed"]:
        return "landed"
    return UNKNOWN if row["ahead"] is None else str(row["ahead"])


def _state_cell(row: dict) -> str:
    if row["dirty"]:
        return "yes"
    if row["dirty"] is None:
        return UNKNOWN
    if row["wip"]:
        return "wip"
    return UNKNOWN if row["wip"] is None else "-"


def _table_row(row: dict) -> list[str]:
    return [
        row["name"],
        row["branch"] or "(detached)",
        "open" if row["open"] else "closed",
        _ahead_cell(row),
        _state_cell(row),
        UNKNOWN if row["idleSeconds"] is None else format_age(row["idleSeconds"]),
    ]


def _die_partial(failures: list[str]) -> NoReturn:
    """Report each failed inspection, then end the listing as partial instead of successful."""
    sys.stdout.flush()
    for failure in failures:
        info(failure)
    die("not every value could be inspected; the listing is partial")


def cmd_list(args: argparse.Namespace) -> None:
    if args.all and args.target:
        die("--all lists every repository; drop it to narrow to one worktree")
    failures: list[str] = []
    documents: list[dict] = []
    names: list[str] = []
    # Listing reports git metadata, so every question it asks must forgo optional locks: a status
    # call that refreshes the index would mutate the checkout and report its own write as 0s idle.
    with read_only_git():
        if args.all:
            found = repos_under_root()
        else:
            here = current_repo()
            found = [Located(name=here.key, repo=here)]
        for item in found:
            repo = item.repo
            if repo is None:
                failures.append(f"{item.name}: {item.error}")
                documents.append(_repo_document(item, []))
                continue
            try:
                selected = [resolve(repo, args.target)] if args.target else entries(repo)
            except ProbeError as error:
                # The repository is there but its worktrees cannot be read: report it, keep the rest.
                failures.append(f"{repo.key}: {error}")
                documents.append(_repo_document(Located(name=repo.key, repo=repo, error=str(error)), []))
                continue
            if args.name:
                names.extend(row.name for row in selected)
                continue
            rows = [inspect_row(repo, entry) for entry in selected]
            failures.extend(f"'{row.name}' in {repo.key}: {row.error}" for row in rows if row.error)
            documents.append(_repo_document(item, rows))
    if args.name:
        for name in names:
            print(name)
        if failures:
            _die_partial(failures)
        return
    if args.json:
        print(json.dumps({"version": STATUS_VERSION, "repos": documents}, indent=2))
    else:
        blocks = []
        for document in documents:
            if not document["worktrees"]:
                continue
            table = [["NAME", "BRANCH", "FOLDER", "AHEAD", "DIRTY", "IDLE"]]
            table.extend(_table_row(row) for row in document["worktrees"])
            blocks.append(f"{document['name']}  ({document['main']})\n{_table(table)}" if args.all else _table(table))
        if blocks:
            print("\n\n".join(blocks))
        elif not failures:
            info("no worktrees")
    sys.stdout.flush()
    if failures:
        _die_partial(failures)


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
