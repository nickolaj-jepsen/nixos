"""wt land: rebase a worktree onto the default branch and fast-forward the default branch onto it."""

from __future__ import annotations

import argparse
import os
import sys
from typing import Optional

from .commands import close_entry, occupants
from .git import die, git, git_ok, info, is_within, run
from .procs import busy_pids, describe_pid
from .repo import Repo, RepoLock, current_repo, registered_worktrees
from .worktrees import Entry, ahead, conflicted, dirty, entries, is_wip, operation_in_progress, resolve


def _dirty_paths(path: str) -> set[str]:
    """Every path whose working-tree or index state a fast-forward could disturb."""
    entries = git(path, "status", "--porcelain", "-z", check=False).split("\0")
    names: set[str] = set()
    index = 0
    while index < len(entries):
        entry = entries[index]
        index += 1
        if len(entry) > 3:
            names.add(entry[3:])
            # A rename carries its source path as the next field.
            if entry[0] in "RC" and index < len(entries) and entries[index]:
                names.add(entries[index])
                index += 1
    return names


def _incoming_paths(repo: Repo, branch: str) -> set[str]:
    out = git(repo.main, "diff", "--name-only", f"{repo.default}...{branch}", "--", check=False)
    return {line for line in out.splitlines() if line}


def default_checkout(repo: Repo) -> Optional[str]:
    """The registered worktree that has the default branch checked out, or None."""
    for item in registered_worktrees(repo.common):
        if item["branch"] == repo.default:
            return item["path"]
    return None


def _require_checkout_ready(repo: Repo, branch: str, checkout: Optional[str]) -> None:
    """Refuse when `checkout` holds uncommitted changes the fast-forward would have to overwrite."""
    if checkout is None:
        return
    dirty_paths = _dirty_paths(checkout)
    if not dirty_paths:
        return
    clash = sorted(dirty_paths & _incoming_paths(repo, branch))
    if not clash:
        info(f"{checkout} has uncommitted changes in {len(dirty_paths)} path(s) this branch does not touch; leaving them")
        return
    die(
        f"{checkout} has uncommitted changes to {', '.join(clash)}, which {branch} also changes, "
        "so git cannot fast-forward over them.\n"
        f"  Yours: commit or stash them in {checkout} first.\n"
        "  Another session's: leave them alone and land once that checkout is clean."
    )


def rebase(entry: Entry, onto: str, *, abort_on_conflict: bool) -> None:
    """Rebase `entry` onto `onto`; a conflict exits, paused or aborted."""
    path = entry.path or ""
    info(f"rebasing {entry.branch} onto {onto}")
    if run(["git", "-C", path, "rebase", "--quiet", onto], check=False).returncode == 0:
        return
    conflicts = conflicted(path)
    print(f"wt: rebase conflict{': ' + ', '.join(conflicts) if conflicts else ''}", file=sys.stderr)
    if abort_on_conflict:
        run(["git", "-C", path, "rebase", "--abort"], check=False)
        die(f"aborted the rebase; {path} is back on {entry.branch}")
    die(
        f"rebase paused in {path}; resolve the conflicts, then "
        f"'wt land --continue {entry.name}' or 'wt land --abort {entry.name}'"
    )


def _fast_forward_default(repo: Repo, entry: Entry) -> None:
    count = ahead(repo, entry.branch)
    checkout = default_checkout(repo)
    if checkout is None:
        # Nothing has the default branch checked out, so move the ref and touch no working tree.
        proc = run(
            ["git", "-C", repo.main, "fetch", "--quiet", ".", f"refs/heads/{entry.branch}:refs/heads/{repo.default}"],
            check=False,
        )
        if proc.returncode != 0:
            die(f"could not fast-forward {repo.default} onto {entry.branch}: {proc.stderr.strip()}")
        info(f"landed {entry.branch} ({count} commit(s)) onto {repo.default}; ref only, since no checkout has it")
        return
    _require_checkout_ready(repo, entry.branch, checkout)
    changed = _incoming_paths(repo, entry.branch)
    if run(["git", "-C", checkout, "merge", "--quiet", "--ff-only", entry.branch], check=False).returncode != 0:
        die(f"could not fast-forward {repo.default} onto {entry.branch}; the rebased branch is left in place")
    info(f"landed {entry.branch} ({count} commit(s)) onto {repo.default}")
    busy = busy_pids(checkout)
    if busy:
        info(f"{len(changed)} path(s) changed under {checkout}, where {describe_pid(busy[0])} is working; tell that session its files moved")


def close_after_landing(repo: Repo, entry: Entry) -> None:
    """Close a landed worktree now, or leave it for the session-exit close when something still works in it."""
    path = entry.path or ""
    if is_within(os.getcwd(), os.path.realpath(path)) or occupants(path):
        info(f"{entry.name} stays open while a session works in it; it closes when that session ends")
        return
    close_entry(repo, entry)


def check_landable(repo: Repo, entry: Entry) -> None:
    """Refuse a worktree whose state no landing path can take."""
    if not entry.open:
        die(f"'{entry.name}' is closed; 'wt new {entry.name}' reopens it")
    path = entry.path or ""
    if not entry.branch:
        die(f"'{entry.name}' is detached; there is no branch to land")
    if entry.branch == repo.default:
        die(f"'{entry.name}' is on {repo.default}; there is nothing to land")
    operation = operation_in_progress(path)
    if operation == "rebase":
        die(f"a rebase is in progress in {path}; finish it with 'wt land --continue' or 'wt land --abort'")
    if operation:
        die(f"'{entry.name}' is in the middle of a {operation}; finish or abort it first")
    if dirty(path):
        die(f"'{entry.name}' has uncommitted changes; commit them inside the worktree first")
    if is_wip(path, "HEAD"):
        die(f"the tip of {entry.branch} is a wip commit from 'wt close'; turn it into a real commit first")


def land_local(repo: Repo, entry: Entry, args: argparse.Namespace) -> None:
    if not ahead(repo, entry.branch):
        info(f"{entry.branch} has nothing that is not already in {repo.default}")
        if not args.dry_run:
            close_after_landing(repo, entry)
        return
    _require_checkout_ready(repo, entry.branch, default_checkout(repo))
    if args.dry_run:
        where = default_checkout(repo) or "the ref only (no checkout has it)"
        info(f"would rebase {entry.branch} onto {repo.default}, fast-forward {where}, then close {entry.name}")
        return
    if not git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"refs/heads/{repo.default}"):
        die(f"no rebase target: local {repo.default} does not exist")
    rebase(entry, repo.default, abort_on_conflict=args.abort_on_conflict)
    _fast_forward_default(repo, entry)
    close_after_landing(repo, entry)


def _resume(repo: Repo, entry: Entry, args: argparse.Namespace) -> None:
    path = entry.path or ""
    if operation_in_progress(path) != "rebase":
        die(f"no rebase in progress in {path}")
    if args.abort:
        run(["git", "-C", path, "rebase", "--abort"])
        info(f"aborted the rebase; {path} is back on {entry.branch}")
        return
    if run(["git", "-C", path, "rebase", "--continue"], check=False).returncode != 0:
        conflicts = conflicted(path)
        die(f"rebase still has conflicts{': ' + ', '.join(conflicts) if conflicts else ''}")
    # Mid-rebase the worktree is detached, so its branch is only known again now.
    entry = next(e for e in entries(repo) if e.path == entry.path)
    _fast_forward_default(repo, entry)
    close_after_landing(repo, entry)


def cmd_land(args: argparse.Namespace) -> None:
    repo = current_repo()
    with RepoLock(repo):
        entry = resolve(repo, args.target or ".")
        if args.continue_rebase or args.abort:
            if not entry.open:
                die(f"'{entry.name}' is closed")
            _resume(repo, entry, args)
            return
        check_landable(repo, entry)
        land_local(repo, entry, args)
