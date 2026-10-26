"""Lifecycle verbs: create, navigate, remove, land, open."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from typing import Optional

from .git import die, git, git_ok, info, is_within, run
from .repo import Repo, RepoLock, current_repo, registered_worktrees
from .status import Worktree, busy_pid, describe_pid, gather, resolve_row
from .trash import archive_orphan, archive_worktree
from .ui import pick


def copy_worktreeinclude(repo: Repo, dest: str) -> None:
    include = os.path.join(repo.main, ".worktreeinclude")
    if not os.path.isfile(include):
        return
    proc = run(
        [
            "git",
            "-C",
            repo.main,
            "ls-files",
            "-z",
            "--others",
            "--ignored",
            "--directory",
            f"--exclude-from={include}",
        ],
        check=False,
    )
    for rel in proc.stdout.split("\0"):
        rel = rel.rstrip("/")
        if not rel:
            continue
        if run(["git", "-C", repo.main, "check-ignore", "-q", "--", rel], check=False).returncode != 0:
            continue
        target = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        run(["cp", "-a", "--", os.path.join(repo.main, rel), target], check=False)


def refresh_origin_default(repo: Repo) -> None:
    if run(["git", "--git-dir", repo.common, "remote", "get-url", "origin"], check=False).returncode != 0:
        return
    ref = f"refs/remotes/origin/{repo.default}"
    fetch_head = os.path.join(repo.common, "FETCH_HEAD")
    if run(["git", "--git-dir", repo.common, "rev-parse", "--verify", "--quiet", ref], check=False).returncode == 0:
        try:
            fetched = int(os.stat(fetch_head).st_mtime)
        except OSError:
            fetched = 0
        if time.time() - fetched <= 86400:
            return
        proc = run(
            ["timeout", "5", "git", "-C", repo.main, "fetch", "--quiet", "origin", repo.default],
            check=False,
        )
        if proc.returncode != 0:
            info(f"fetch of origin/{repo.default} failed; basing on the local ref")
    else:
        run(
            ["git", "-C", repo.main, "fetch", "--quiet", "origin", repo.default],
            check=False,
        )


def cmd_create(args: argparse.Namespace) -> None:
    repo = current_repo()
    with RepoLock(repo):
        branch = args.name
        directory_name = args.name.replace("/", "-")
        path = os.path.join(repo.directory, directory_name)
        if os.path.exists(path):
            die(f"'{path}' already exists")
        if git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"):
            die(f"branch '{branch}' already exists; pick another name, or check it out yourself")
        base_ref: Optional[str] = None
        if args.base:
            if not git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"{args.base}^{{commit}}"):
                die(f"base ref '{args.base}' not found")
            base_ref = args.base
        else:
            refresh_origin_default(repo)
            if git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{repo.default}"):
                base_ref = f"origin/{repo.default}"
            elif git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"refs/heads/{repo.default}"):
                base_ref = repo.default
            else:
                die(f"no base: neither origin/{repo.default} nor {repo.default} exists")
        info(f"creating worktree '{directory_name}' on new branch '{branch}' off {base_ref}")
        run(["git", "-C", repo.main, "worktree", "add", "-b", branch, path, base_ref])
        copy_worktreeinclude(repo, path)
        print(path)


def cmd_cd(args: argparse.Namespace) -> None:
    repo = current_repo()
    if args.main:
        print(repo.main)
        return
    if args.target:
        row = resolve_row(repo, args.target, gather(repo, deep=False))
    else:
        row = pick(repo, "cd", gather(repo))
    if not os.path.isdir(row.path):
        die(f"'{row.name}' has no directory at {row.path}")
    print(row.path)


def cmd_names(args: argparse.Namespace) -> None:
    repo = current_repo()
    for row in gather(repo, deep=False):
        if not row.is_main:
            print(row.name)


def drop_branch(repo: Repo, branch: str) -> None:
    if branch and branch != repo.default:
        run(["git", "-C", repo.main, "branch", "-D", branch], check=False)


def _remove_row(repo: Repo, row: Worktree, *, force: bool, ignore_in_use: bool) -> None:
    busy = busy_pid(row.path)
    if busy and not ignore_in_use:
        die(f"'{row.name}' is in use: {describe_pid(busy)} has its cwd inside; close it, or ask before --ignore-in-use")
    if row.registered and row.locked:
        die(f"'{row.name}' is locked. Run: git -C '{repo.main}' worktree unlock '{row.path}'")
    if not row.registered:
        if not force and row.safe_to_remove:
            run(["rm", "-rf", "--", row.path])
            info(f"removed (orphan)     {row.name}")
            return
        if not force:
            die(f"'{row.name}' is an orphan with files inside; inspect {row.path} or pass --force")
        archive_orphan(repo, row)
        info(f"archived (orphan)    {row.name}")
        return

    if not force:
        if row.state != "clean":
            die(f"'{row.name}' has uncommitted changes ({row.state}); commit/stash inside the worktree, or pass --force")
        if not row.landed:
            die(f"'{row.name}' has work not on {repo.default}; run 'wt land {row.name}' to keep it, or pass --force")
        run(["git", "-C", repo.main, "worktree", "remove", row.path])
        drop_branch(repo, row.branch)
        info(f"removed (registered) {row.name}")
        return

    trash_id = archive_worktree(repo, row)
    run(["git", "-C", repo.main, "worktree", "remove", "--force", row.path])
    drop_branch(repo, row.branch)
    info(f"archived {row.name} as {trash_id}; restore with: wt restore {trash_id}")


def cmd_clean(args: argparse.Namespace) -> None:
    repo = current_repo()
    with RepoLock(repo):
        rows = gather(repo)
        removed = skipped = 0
        for row in rows:
            if row.is_main or not row.safe_to_remove:
                skipped += 1
                continue
            if row.branch == repo.default:
                skipped += 1
                continue
            if is_within(os.getcwd(), os.path.realpath(row.path)):
                info(f"skipping {row.name}: it holds this cwd, so run 'wt clean' from {repo.main}")
                skipped += 1
                continue
            if args.dry_run:
                info(f"would remove {row.name}")
                removed += 1
                continue
            if row.registered:
                run(["git", "-C", repo.main, "worktree", "remove", row.path])
                drop_branch(repo, row.branch)
                info(f"removed (registered) {row.name}")
            else:
                run(["rm", "-rf", "--", row.path])
                info(f"removed (orphan)     {row.name}")
            removed += 1
        if not args.dry_run:
            run(["git", "-C", repo.main, "worktree", "prune"], check=False)
        verb = "would remove" if args.dry_run else "removed"
        info(f"{verb} {removed}, {skipped} left")


def cmd_remove(args: argparse.Namespace) -> None:
    # A path names its own repository, so a hook can remove without standing in a checkout.
    repo = current_repo(args.target if os.path.isabs(args.target) and os.path.isdir(args.target) else None)
    with RepoLock(repo):
        rows = gather(repo)
        row = resolve_row(repo, args.target, rows)
        if row.is_main:
            die(f"'{row.name}' is the main checkout — cannot remove")
        if args.dry_run:
            if is_within(os.getcwd(), os.path.realpath(row.path)):
                info(f"would refuse {row.name}: holds this cwd")
            elif row.safe_to_remove:
                info(f"would remove {row.name}")
            elif row.busy and not args.ignore_in_use:
                info(f"would refuse {row.name}: in use")
            elif row.locked:
                info(f"would refuse {row.name}: locked")
            elif row.state != "clean" and not args.force:
                info(f"would refuse {row.name}: {row.state}")
            elif not row.landed and not args.force:
                info(f"would refuse {row.name}: unlanded work")
            else:
                info(f"would archive and remove {row.name}")
            return
        _require_outside_worktree(repo, row)
        _remove_row(repo, row, force=args.force, ignore_in_use=args.ignore_in_use)
        run(["git", "-C", repo.main, "worktree", "prune"], check=False)


# ---------------------------------------------------------------------------
# Rebase lifecycle


def _rebase_in_progress(path: str) -> bool:
    for name in ("rebase-merge", "rebase-apply"):
        proc = run(["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-path", name], check=False)
        if proc.returncode == 0 and os.path.exists(proc.stdout.strip()):
            return True
    return False


def current_branch(path: str) -> str:
    proc = run(["git", "-C", path, "symbolic-ref", "--short", "--quiet", "HEAD"], check=False)
    return proc.stdout.strip()


def _conflicted(path: str) -> list[str]:
    proc = run(["git", "-C", path, "diff", "--name-only", "--diff-filter=U"], check=False)
    return [line for line in proc.stdout.splitlines() if line]


def _dirty_paths(path: str) -> set[str]:
    """Every path whose working-tree or index state a fast-forward could disturb."""
    proc = run(["git", "-C", path, "status", "--porcelain", "-z"], check=False)
    names: set[str] = set()
    entries = proc.stdout.split("\0")
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


def _incoming_paths(repo: Repo, row: Worktree) -> set[str]:
    proc = run(
        ["git", "-C", repo.main, "diff", "--name-only", f"{repo.default}...{row.branch}"], check=False
    )
    return {line for line in proc.stdout.splitlines() if line}


def _default_checkout(repo: Repo) -> Optional[str]:
    """The registered worktree that has the default branch checked out, or None."""
    for item in registered_worktrees(repo.common):
        if item["branch"] == repo.default:
            return item["path"]
    return None


def _require_checkout_ready(repo: Repo, row: Worktree, checkout: Optional[str]) -> None:
    """Refuse when `checkout` holds uncommitted changes the fast-forward would have to overwrite."""
    if checkout is None:
        return
    dirty = _dirty_paths(checkout)
    if not dirty:
        return
    clash = sorted(dirty & _incoming_paths(repo, row))
    if not clash:
        info(
            f"{checkout} has uncommitted changes in {len(dirty)} path(s) this branch does not touch; "
            "leaving them as they are"
        )
        return
    die(
        f"{checkout} has uncommitted changes to {', '.join(clash)}, which {row.branch} also "
        "changes, so git cannot fast-forward over them.\n"
        f"  Yours: commit or stash them in {checkout} first.\n"
        "  Another session's: leave them alone and land this branch once that checkout is clean."
    )


def _require_outside_worktree(repo: Repo, row: Worktree) -> None:
    """Refuse a removal that would delete the directory the caller is standing in."""
    if not is_within(os.getcwd(), os.path.realpath(row.path)):
        return
    die(
        f"you are inside worktree '{row.name}', and removing it deletes that directory.\n"
        f"From the primary checkout instead:\n"
        f"  cd {repo.main} && wt remove {row.name}"
    )


def _rebase(repo: Repo, row: Worktree, *, abort_on_conflict: bool) -> None:
    """Rebase `row` onto local default; a conflict exits, paused or aborted."""
    target = repo.default
    if not git_ok(row.path, "rev-parse", "--verify", "--quiet", f"refs/heads/{target}"):
        die(f"no rebase target: local {target} does not exist")
    info(f"rebasing {row.branch} onto {target}")
    proc = run(["git", "-C", row.path, "rebase", target], check=False)
    if proc.returncode == 0:
        return
    conflicts = _conflicted(row.path)
    detail = f": {', '.join(conflicts)}" if conflicts else ""
    print(f"wt: rebase conflict{detail}", file=sys.stderr)
    if abort_on_conflict:
        run(["git", "-C", row.path, "rebase", "--abort"], check=False)
        info(f"aborted the rebase; {row.path} is back on {row.branch}")
        raise SystemExit(1)
    info(
        f"rebase paused in {row.path}; resolve the conflicts, then "
        f"'wt land --continue {row.name}' or 'wt land --abort {row.name}'"
    )
    raise SystemExit(1)


def _finish_land(repo: Repo, row: Worktree) -> None:
    count = int(git(repo.main, "rev-list", "--count", f"{repo.default}..{row.branch}", check=False).strip() or 0)
    checkout = _default_checkout(repo)
    if checkout is None:
        # Nothing has the default branch checked out, so move the ref and touch no working tree.
        proc = run(
            ["git", "-C", row.path, "fetch", "--quiet", ".", f"refs/heads/{row.branch}:refs/heads/{repo.default}"],
            check=False,
        )
        if proc.returncode != 0:
            die(f"could not fast-forward {repo.default} onto {row.branch}: {proc.stderr.strip()}")
        info(
            f"landed {row.branch} ({count} commit(s)) onto {repo.default}, ref only since no checkout "
            f"has it; worktree kept at {row.path}"
        )
        return
    _require_checkout_ready(repo, row, checkout)
    changed = _incoming_paths(repo, row)
    if run(["git", "-C", checkout, "merge", "--ff-only", row.branch], check=False).returncode != 0:
        die(f"could not fast-forward {repo.default} onto {row.branch}; the rebased branch is left in place")
    info(f"landed {row.branch} ({count} commit(s)) onto {repo.default}; worktree kept at {row.path}")
    busy = busy_pid(checkout)
    if busy:
        info(
            f"{len(changed)} path(s) changed under {checkout}, where {describe_pid(busy)} is working; "
            "tell that session its files moved"
        )


def cmd_land(args: argparse.Namespace) -> None:
    repo = current_repo()
    with RepoLock(repo):
        rows = gather(repo)
        if args.continue_rebase or args.abort:
            row = resolve_row(repo, args.target or ".", rows)
            if not _rebase_in_progress(row.path):
                die(f"no rebase in progress in {row.path}")
            if args.abort:
                run(["git", "-C", row.path, "rebase", "--abort"])
                info(f"aborted the rebase; {row.path} is back on {current_branch(row.path) or 'its branch'}")
                return
            proc = run(["git", "-C", row.path, "rebase", "--continue"], check=False)
            if proc.returncode != 0:
                conflicts = _conflicted(row.path)
                detail = f": {', '.join(conflicts)}" if conflicts else ""
                die(f"rebase still has conflicts{detail}")
            _finish_land(repo, resolve_row(repo, args.target or row.name, gather(repo)))
            return

        row = resolve_row(repo, args.target or ".", rows) if args.target else _pick_target(repo, rows, "land", landable=True)
        if row.is_main:
            die(f"'{row.name}' is the main checkout — nothing to land")
        if not row.registered:
            die(f"'{row.name}' is an orphan — nothing to land, run 'wt remove' instead")
        if row.detached:
            die(f"'{row.name}' is detached (no branch to land)")
        if row.branch == repo.default:
            die(f"'{row.name}' is on the default branch — nothing to land")
        if row.state != "clean":
            die(f"'{row.name}' has uncommitted changes ({row.state}); commit or stash inside the worktree first")
        if row.locked:
            die(f"'{row.name}' is locked. Run: git -C '{repo.main}' worktree unlock '{row.path}'")
        if _rebase_in_progress(row.path):
            die(f"a rebase is in progress in {row.path}; finish it with 'wt land --continue' or 'wt land --abort'")
        if not row.ahead:
            die(f"'{row.name}' has nothing to land: no commits ahead of {repo.default}; run 'wt clean' to remove it")
        checkout = _default_checkout(repo)
        _require_checkout_ready(repo, row, checkout)
        if args.dry_run:
            where = f"fast-forward it in {checkout}" if checkout else "move the ref (no checkout has it)"
            info(f"would rebase {row.branch} onto {repo.default} and {where}, keeping the worktree")
            return
        _rebase(repo, row, abort_on_conflict=bool(args.abort_on_conflict))
        _finish_land(repo, row)


def _pick_target(repo: Repo, rows: list[Worktree], prompt: str, *, landable: bool = False) -> Worktree:
    candidates = [
        row
        for row in rows
        if row.registered and not row.is_main and not row.detached and row.branch != repo.default
    ]
    if landable:
        candidates = [row for row in candidates if row.ahead]
    if not candidates:
        die(f"no worktrees to {prompt}")
    return pick(repo, prompt, candidates)


def _open(repo: Repo, target: str, prompt: str, tool: str, args: list[str]) -> None:
    rows = gather(repo)
    row = resolve_row(repo, target, rows) if target else _pick_target(repo, rows, prompt)
    if row.is_main:
        die(f"'{row.name}' is the main checkout — open it directly")
    if not row.registered:
        die(f"'{row.name}' is an orphan — nothing to open")
    info(f"opening {row.path} in {tool}")
    subprocess.Popen([*args, row.path], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def cmd_smerge(args: argparse.Namespace) -> None:
    if not shutil.which("smerge"):
        die("sublime-merge ('smerge') not found on PATH")
    _open(current_repo(), args.target, "smerge", "sublime-merge", ["smerge"])


def cmd_code(args: argparse.Namespace) -> None:
    if not shutil.which("code"):
        die("VS Code ('code') not found on PATH")
    _open(current_repo(), args.target, "code", "VS Code", ["code", "-n"])
