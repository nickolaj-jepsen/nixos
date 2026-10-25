"""Lifecycle verbs: create, navigate, remove, land, sync, review."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from typing import Optional

from .git import die, git, git_ok, info, is_within, run
from .repo import Repo, RepoLock, current_repo
from .status import Worktree, busy_pid, gather, resolve_row
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
        info(
            f"landing: commit here, then 'wt apply {branch}' puts the commits on {repo.default} and\n"
            f"keeps this worktree; 'wt apply --remove {branch}' from {repo.main} deletes it;\n"
            "'wt clean' sweeps landed worktrees"
        )
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


def cmd_migrate(args: argparse.Namespace) -> None:
    repo = current_repo()
    with RepoLock(repo):
        rows = gather(repo)
        moved = skipped = 0
        for row in rows:
            if row.is_main or not row.registered:
                if not row.registered and not is_within(row.path, repo.directory):
                    info(f"left orphan {row.path} in place — inspect it, then 'wt remove --force' or move it yourself")
                    skipped += 1
                continue
            if is_within(row.path, repo.directory):
                continue
            dest = os.path.join(repo.directory, os.path.basename(row.path))
            if os.path.exists(dest):
                info(f"skipped {row.name}: {dest} already exists")
                skipped += 1
                continue
            if args.dry_run:
                info(f"would move {row.path} -> {dest}")
                moved += 1
                continue
            proc = run(["git", "-C", repo.main, "worktree", "move", row.path, dest], check=False)
            if proc.returncode == 0:
                info(f"moved {row.name} -> {dest}")
                moved += 1
            else:
                info(
                    f"skipped {row.name}: git would not move it (locked, or holds submodules); "
                    f"unlock with: git -C '{repo.main}' worktree unlock '{row.path}'"
                )
                skipped += 1
        if args.dry_run:
            info(f"would move {moved}, {skipped} left")
        else:
            run(["git", "-C", repo.main, "worktree", "prune"], check=False)
            info(f"moved {moved}, {skipped} left alone" if moved else f"nothing to move, {skipped} left alone")


def drop_branch(repo: Repo, branch: str) -> None:
    if branch and branch != repo.default:
        run(["git", "-C", repo.main, "branch", "-D", branch], check=False)


def _remove_row(repo: Repo, row: Worktree, *, force: bool, ignore_in_use: bool) -> None:
    busy = busy_pid(row.path)
    if busy and not ignore_in_use:
        die(f"'{row.name}' is in use: process {busy} has its cwd inside; close it, or pass --ignore-in-use")
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
            die(f"'{row.name}' has work not on {repo.default}; run 'wt apply {row.name}' to keep it, or pass --force")
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
    repo = current_repo()
    with RepoLock(repo):
        rows = gather(repo)
        row = resolve_row(repo, args.target, rows)
        if row.is_main:
            die(f"'{row.name}' is the main checkout — cannot remove")
        if args.dry_run:
            if row.safe_to_remove:
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


def _require_main_ready(repo: Repo, row: Worktree) -> None:
    """Refuse when the primary checkout cannot fast-forward onto `row.branch`."""
    branch = run(["git", "-C", repo.main, "symbolic-ref", "--short", "--quiet", "HEAD"], check=False)
    if branch.returncode != 0:
        die(f"main checkout is in detached HEAD; checkout {repo.default} first")
    if branch.stdout.strip() != repo.default:
        die(f"main checkout is on '{branch.stdout.strip()}', not '{repo.default}'; park it on '{repo.default}' first")
    dirty = _dirty_paths(repo.main)
    if not dirty:
        return
    clash = sorted(dirty & _incoming_paths(repo, row))
    if not clash:
        info(
            f"main checkout has uncommitted changes in {len(dirty)} path(s) this branch does not touch; "
            "leaving them as they are"
        )
        return
    die(
        f"the main checkout has uncommitted changes to {', '.join(clash)}, which {row.branch} also "
        "changes, so git cannot fast-forward over them.\n"
        f"  Yours: commit or stash them in {repo.main} first.\n"
        "  Another session's: leave them alone and land this branch once that checkout is clean."
    )


def _require_outside_worktree(repo: Repo, row: Worktree) -> None:
    """Refuse a removal that would delete the directory the caller is standing in."""
    if not is_within(os.getcwd(), os.path.realpath(row.path)):
        return
    die(
        f"you are inside worktree '{row.name}', and removing it deletes that directory.\n"
        f"Run it from the primary checkout instead:\n  cd {repo.main} && wt apply --remove {row.name}\n"
        f"Or land now and delete the worktree once nothing works in it:\n"
        f"  wt apply {row.name} && wt remove {row.name}"
    )


def _rebase(repo: Repo, row: Worktree, *, abort_on_conflict: bool, verb: str) -> bool:
    """Rebase `row` onto local default. Returns True on success, False on conflict."""
    target = repo.default
    if not git_ok(row.path, "rev-parse", "--verify", "--quiet", f"refs/heads/{target}"):
        die(f"no rebase target: local {target} does not exist")
    info(f"rebasing {row.branch} onto {target}")
    proc = run(["git", "-C", row.path, "rebase", target], check=False)
    if proc.returncode == 0:
        return True
    conflicts = _conflicted(row.path)
    detail = f": {', '.join(conflicts)}" if conflicts else ""
    print(f"wt: rebase conflict{detail}", file=sys.stderr)
    if abort_on_conflict:
        run(["git", "-C", row.path, "rebase", "--abort"], check=False)
        info(f"aborted the rebase; {row.path} is back on {row.branch}")
        raise SystemExit(1)
    info(
        f"rebase paused in {row.path}; resolve the conflicts, then "
        f"'wt {verb} --continue {row.name}' or 'wt {verb} --abort {row.name}'"
    )
    raise SystemExit(1)


def _finish_apply(repo: Repo, row: Worktree, landed_before: int, *, remove: bool) -> None:
    if remove:
        _require_outside_worktree(repo, row)
    # Fast-forward before removing anything, so a refused FF leaves the worktree to fix in.
    if run(["git", "-C", repo.main, "merge", "--ff-only", row.branch], check=False).returncode != 0:
        die(
            f"could not fast-forward {repo.default} onto {row.branch}; "
            f"the rebased branch is left in place — merge it manually"
        )
    if not remove:
        info(f"landed {row.branch} ({landed_before} commit(s)) onto {repo.default}; worktree kept at {row.path}")
        return
    info(f"removing worktree {row.path}")
    run(["git", "-C", repo.main, "worktree", "remove", row.path])
    if git_ok(repo.main, "merge-base", "--is-ancestor", row.branch, "HEAD"):
        run(["git", "-C", repo.main, "branch", "-D", row.branch], check=False)
    else:
        info(f"landed {row.branch} but it is not contained in {repo.default}; branch left in place")
    info(f"landed and removed {row.branch} ({landed_before} commit(s)) onto {repo.default}")


def cmd_apply(args: argparse.Namespace) -> None:
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
            row = resolve_row(repo, args.target or row.name, gather(repo))
            _require_main_ready(repo, row)
            landed = int(git(repo.main, "rev-list", "--count", f"{repo.default}..{row.branch}", check=False).strip() or 0)
            _finish_apply(repo, row, landed, remove=args.remove)
            return

        row = resolve_row(repo, args.target or ".", rows) if args.target else _pick_target(repo, rows, "apply", applyable=True)
        if row.is_main:
            die(f"'{row.name}' is the main checkout — nothing to apply")
        if not row.registered:
            die(f"'{row.name}' is an orphan — nothing to apply, run 'remove' instead")
        if row.detached:
            die(f"'{row.name}' is detached (no branch to keep)")
        if row.branch == repo.default:
            die(f"'{row.name}' is on the default branch — nothing to apply")
        if row.state != "clean":
            die(f"'{row.name}' has uncommitted changes ({row.state}); commit or stash inside the worktree first")
        if row.locked:
            die(f"'{row.name}' is locked. Run: git -C '{repo.main}' worktree unlock '{row.path}'")
        if _rebase_in_progress(row.path):
            die(f"a rebase is in progress in {row.path}; finish it with 'wt apply --continue' or 'wt apply --abort'")
        if not row.ahead:
            die(f"'{row.name}' has nothing to land: no commits ahead of {repo.default}; run 'wt clean' to remove it")
        _require_main_ready(repo, row)
        if args.remove and not args.dry_run:
            _require_outside_worktree(repo, row)
        if args.dry_run:
            if args.remove:
                if is_within(os.getcwd(), os.path.realpath(row.path)):
                    info(f"note: --remove would refuse here, since it deletes {row.path}, which holds this cwd")
                info(
                    f"would rebase {row.branch} onto {repo.default}, fast-forward it, then remove "
                    f"the worktree and delete the branch"
                )
            else:
                info(f"would rebase {row.branch} onto {repo.default} and fast-forward it, keeping the worktree")
            return
        _rebase(repo, row, abort_on_conflict=bool(args.abort_on_conflict), verb="apply")
        landed = int(git(repo.main, "rev-list", "--count", f"{repo.default}..{row.branch}", check=False).strip() or 0)
        _finish_apply(repo, row, landed, remove=args.remove)


def cmd_sync(args: argparse.Namespace) -> None:
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
            info(f"synced {current_branch(row.path) or row.name} onto {repo.default}")
            return

        row = resolve_row(repo, args.target or ".", rows) if args.target else _pick_target(repo, rows, "sync")
        if row.is_main:
            die(f"'{row.name}' is the main checkout — nothing to sync")
        if not row.registered or row.detached:
            die(f"'{row.name}' has no branch to sync")
        if row.state != "clean":
            die(f"'{row.name}' has uncommitted changes ({row.state}); commit or stash inside the worktree first")
        if _rebase_in_progress(row.path):
            die(f"a rebase is in progress in {row.path}; finish it with 'wt sync --continue' or 'wt sync --abort'")
        if args.dry_run:
            info(f"would rebase {row.branch} onto {repo.default}")
            return
        _rebase(repo, row, abort_on_conflict=bool(args.abort_on_conflict), verb="sync")
        info(f"synced {row.branch} onto {repo.default}")


def _pick_target(repo: Repo, rows: list[Worktree], prompt: str, *, applyable: bool = False) -> Worktree:
    candidates = [
        row
        for row in rows
        if row.registered and not row.is_main and not row.detached and row.branch != repo.default
    ]
    if applyable:
        candidates = [row for row in candidates if row.ahead]
    if not candidates:
        die(f"no worktrees to {prompt}")
    return pick(repo, prompt, candidates)


def _diff_base(repo: Repo, path: str) -> str:
    if git_ok(path, "rev-parse", "--verify", "--quiet", f"refs/heads/{repo.default}"):
        return repo.default
    if git_ok(path, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{repo.default}"):
        return f"origin/{repo.default}"
    die(f"no base to diff against: neither local {repo.default} nor origin/{repo.default} exists")


def cmd_diff(args: argparse.Namespace) -> None:
    repo = current_repo()
    rows = gather(repo)
    row = resolve_row(repo, args.target, rows) if args.target else _pick_target(repo, rows, "diff")
    if row.is_main:
        die(f"'{row.name}' is the main checkout — nothing to diff")
    if not row.registered:
        die(f"'{row.name}' is an orphan — nothing to diff")
    if row.detached:
        die(f"'{row.name}' is detached — no branch to diff")
    base = _diff_base(repo, row.path)
    if args.stat or args.name_only or args.patch:
        merge_base = git(row.path, "merge-base", base, "HEAD", check=False).strip()
        rev = f"{merge_base}..HEAD" if merge_base else base
        if args.name_only:
            print(git(row.path, "diff", "--name-only", rev), end="")
        elif args.stat:
            print(git(row.path, "diff", "--stat", rev), end="")
        else:
            print(git(row.path, "diff", rev), end="")
        untracked = git(row.path, "ls-files", "--others", "--exclude-standard", check=False)
        if untracked.strip():
            info(f"note: '{row.name}' has untracked files not shown in this diff")
        return
    if row.ahead == 0 and row.state == "clean":
        info(f"'{row.name}' has no changes vs {repo.default}")
        return
    if not shutil.which("diffnav"):
        die("diffnav not found on PATH")
    untracked = git(row.path, "ls-files", "--others", "--exclude-standard", check=False)
    if untracked.strip():
        info(f"note: '{row.name}' has untracked files not shown in this diff")
    merge_base = git(row.path, "merge-base", base, "HEAD", check=False).strip()
    command = f"git diff {merge_base}" if merge_base else f"git diff {base}"
    subprocess.run(["diffnav", "--watch", "--watch-cmd", command], cwd=row.path)


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
