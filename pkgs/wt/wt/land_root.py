"""wt land from the primary checkout: push the default branch, or land the branch checked out there.

The primary checkout is shared with other sessions and never closed, so its uncommitted changes
are left alone unless a step would overwrite one, and every branch switch names who works there.
"""

from __future__ import annotations

import argparse
import os

from .gh import has_origin, pr_view, stack
from .git import ProbeError, die, git_ok, info, inspect, is_within, probe, run
from .land import (
    changed_paths,
    clashes,
    default_checkout,
    guard_moves,
    land_pr,
    rebase,
    rebase_moves,
    tell_sessions,
)
from .repo import Repo
from .worktrees import Entry, ahead, branch_exists, conflicted, dir_name, entries, is_wip, operation_in_progress


def root_branch(repo: Repo) -> str:
    """The branch the primary checkout has checked out; empty when it is detached."""
    return inspect(repo.main, lambda: probe(repo.main, "branch", "--show-current").strip())


def targets_root(repo: Repo, target: str) -> bool:
    """Whether `target` (`.`, a path, or a name) means the primary checkout rather than a worktree.

    A name means the primary checkout only when no worktree answers to it and it is the branch
    checked out there; a branch checked out nowhere is refused, since landing needs a working tree.
    """
    known = entries(repo)
    if target == "." or os.path.isabs(target):
        inside = os.path.realpath(os.getcwd() if target == "." else target)
        return is_within(inside, os.path.realpath(repo.main)) and not any(
            entry.path and is_within(inside, os.path.realpath(entry.path)) for entry in known
        )
    if any(target in (entry.name, entry.branch) or entry.name == dir_name(target) for entry in known):
        return False
    if target == root_branch(repo):
        return True
    if branch_exists(repo, target):
        die(f"{target} is not checked out anywhere; open it with 'wt new {target}' or check it out in {repo.main}, then land")
    return False


def _count(path: str, revisions: str) -> int:
    out = inspect(path, lambda: probe(path, "rev-list", "--count", revisions, "--").strip())
    if not out.isdigit():
        die(f"git rev-list --count {revisions} answered {out!r}, not a count")
    return int(out)


def _fetch(repo: Repo) -> str:
    """Fetch the default branch from origin and name its remote-tracking ref."""
    run(["timeout", "20", "git", "-C", repo.main, "fetch", "--quiet", "origin", repo.default], check=False)
    upstream = f"origin/{repo.default}"
    if not git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"refs/remotes/{upstream}"):
        die(f"there is no {upstream} to land onto")
    return upstream


def land_root(repo: Repo, args: argparse.Namespace) -> None:
    path = repo.main
    if args.continue_rebase or args.abort:
        _resume(repo, args)
        return
    operation = inspect(path, lambda: operation_in_progress(path))
    if operation == "rebase":
        die(f"a rebase is in progress in {path}; finish it with 'wt land --continue' or 'wt land --abort'")
    if operation:
        die(f"{path} is in the middle of a {operation}; finish or abort it first")
    branch = root_branch(repo)
    if not branch:
        die(f"{path} is detached; there is no branch to land")
    if branch == repo.default:
        if args.mode:
            _carve(repo, args)
        else:
            _push_default(repo, args)
        return
    if args.rebase:
        die(f"--rebase applies to pushing {repo.default}; a branch is always rebased onto it")
    if args.branch:
        die(f"--branch names the branch {repo.default}'s commits move to; {path} is already on {branch}")
    _land_branch(repo, branch, args)


# ---------------------------------------------------------------------------
# The default branch itself


def _push_default(repo: Repo, args: argparse.Namespace) -> None:
    """Push local <default> to origin, fast-forward only, rebasing it first only when --rebase asks."""
    path = repo.main
    if args.branch:
        die("--branch moves the commits to a branch for a PR; pass --draft, --pr or --green with it")
    if not has_origin(repo):
        die(f"there is no origin remote to push {repo.default} to")
    upstream = _fetch(repo)
    unpushed = _count(path, f"{upstream}..{repo.default}")
    behind = _count(path, f"{repo.default}..{upstream}")
    if not unpushed:
        info(f"{repo.default} has nothing that {upstream} lacks; nothing to push"
             + (f" (it is {behind} commit(s) behind: git -C {path} pull --ff-only)" if behind else ""))
        return
    if behind:
        if not args.rebase:
            die(f"{upstream} is {behind} commit(s) ahead of local {repo.default}; rerun with --rebase "
                f"to rebase {repo.default} onto it, then push")
        if args.dry_run:
            info(f"would rebase {repo.default} onto {upstream}, then push {unpushed} commit(s)")
            return
        guard_moves(path, lambda: rebase_moves(path, upstream, upstream), f"rebasing {repo.default} onto {upstream}")
        rebase(Entry(repo.default, repo.default, path), upstream,
               abort_on_conflict=args.abort_on_conflict, autostash=True, resume="")
        tell_sessions(repo, f"files moved under it when {repo.default} was rebased onto {upstream}")
    elif args.dry_run:
        info(f"would push {unpushed} commit(s) of {repo.default} to {upstream}")
        return
    _push(repo, upstream)


def _push(repo: Repo, upstream: str) -> None:
    count = _count(repo.main, f"{upstream}..{repo.default}")
    proc = run(["git", "-C", repo.main, "push", "--quiet", "origin", f"refs/heads/{repo.default}:refs/heads/{repo.default}"],
               check=False)
    if proc.returncode:
        die(f"git push of {repo.default} failed: {(proc.stderr or proc.stdout).strip()}")
    info(f"pushed {count} commit(s) of {repo.default} to {upstream}")


def _carve(repo: Repo, args: argparse.Namespace) -> None:
    """Move <default>'s unpushed commits to a new branch for a PR, then land that branch through GitHub.

    The primary checkout switches to the new branch at the same commit, so no file moves, and local
    <default> goes back to origin's: the commits now live only on the branch.
    """
    path = repo.main
    name = args.branch
    if not name:
        die(f"landing {repo.default} through a PR needs --branch <name> for the branch its commits move to")
    if args.rebase:
        die("--rebase applies to pushing the default branch; a PR's branch is always rebased onto origin")
    if branch_exists(repo, name):
        die(f"branch '{name}' already exists; pick another --branch")
    if not git_ok(path, "check-ref-format", "--branch", name):
        die(f"'{name}' is not a valid branch name")
    if not has_origin(repo):
        die("there is no origin remote; push or land locally instead")
    upstream = _fetch(repo)
    count = _count(path, f"{upstream}..{repo.default}")
    if not count:
        die(f"{repo.default} has nothing that {upstream} lacks; no PR to open")
    if args.dry_run:
        info(f"would move {count} commit(s) from {repo.default} to {name}, reset {repo.default} to {upstream}, "
             f"and open a {'draft ' if args.mode == 'draft' else ''}PR")
        return
    run(["git", "-C", path, "switch", "--quiet", "-c", name])
    run(["git", "-C", path, "branch", "--quiet", "--force", repo.default, upstream])
    info(f"moved {count} commit(s) from {repo.default} to {name}; {repo.default} is back at {upstream}")
    tell_sessions(repo, f"it is now on {name}, with the same files")
    _land_branch_pr(repo, name, args)


# ---------------------------------------------------------------------------
# A branch checked out in the primary checkout


def _land_branch(repo: Repo, branch: str, args: argparse.Namespace) -> None:
    path = repo.main
    if has_origin(repo) and stack(path):
        die(f"{path} holds a gh stack; land stacks from a worktree")
    if inspect(path, lambda: is_wip(path, "HEAD")):
        die(f"the tip of {branch} is a wip commit from 'wt close'; turn it into a real commit first")
    if args.mode:
        _land_branch_pr(repo, branch, args)
        return
    holder = default_checkout(repo)
    if holder:
        die(f"{repo.default} is checked out in {holder}; land from there or free it")
    if not git_ok(path, "rev-parse", "--verify", "--quiet", f"refs/heads/{repo.default}"):
        die(f"no rebase target: local {repo.default} does not exist")
    if not inspect(branch, lambda: ahead(repo, branch)):
        info(f"{branch} has nothing that is not already in {repo.default}")
        if not args.dry_run:
            _switch_to_default(repo, branch, merged=False)
        return
    if args.dry_run:
        info(f"would rebase {branch} onto {repo.default}, fast-forward {repo.default}, "
             f"switch {path} to it and delete {branch}")
        return
    guard_moves(path, lambda: rebase_moves(path, repo.default, repo.default), f"rebasing {branch} onto {repo.default}")
    rebase(Entry(branch, branch, path), repo.default, abort_on_conflict=args.abort_on_conflict, autostash=True, resume="")
    _finish_branch(repo, branch)


def _finish_branch(repo: Repo, branch: str) -> None:
    """Fast-forward <default> onto the rebased branch, then put the primary checkout on <default>."""
    count = inspect(branch, lambda: ahead(repo, branch))
    # <default> is checked out nowhere, so this moves the ref and no files.
    proc = run(["git", "-C", repo.main, "fetch", "--quiet", ".", f"refs/heads/{branch}:refs/heads/{repo.default}"],
               check=False)
    if proc.returncode:
        die(f"could not fast-forward {repo.default} onto {branch}: {proc.stderr.strip()}")
    info(f"landed {branch} ({count} commit(s)) onto {repo.default}")
    _switch_to_default(repo, branch, merged=False)


def _switch_to_default(repo: Repo, branch: str, *, merged: bool) -> None:
    """Switch the primary checkout from `branch` to <default>, then delete `branch`.

    `merged` says GitHub merged the branch: <default> then fast-forwards to origin's, and the branch
    goes with -D, since a rebase merge leaves its commits unreachable from <default>.
    """
    path = repo.main
    final = repo.default
    if merged:
        run(["timeout", "20", "git", "-C", path, "fetch", "--quiet", "origin", repo.default], check=False)
        upstream = f"origin/{repo.default}"
        if git_ok(path, "merge-base", "--is-ancestor", repo.default, upstream):
            final = upstream
    clash = clashes(path, lambda: changed_paths(path, "HEAD", final))
    if clash:
        steps = f"git switch {repo.default}" + (f" && git merge --ff-only {final}" if final != repo.default else "")
        die(f"{path} has uncommitted changes to {', '.join(clash)}, which switching to {repo.default} would change; "
            f"it stays on {branch}. Once they are committed or gone: {steps} && git branch -{'D' if merged else 'd'} {branch}")
    run(["git", "-C", path, "switch", "--quiet", repo.default])
    if final != repo.default:
        run(["git", "-C", path, "merge", "--quiet", "--ff-only", final])
    elif merged:
        info(f"local {repo.default} has commits origin/{repo.default} lacks, so it was not fast-forwarded")
    deleted = run(["git", "-C", path, "branch", "-D" if merged else "-d", branch], check=False)
    if deleted.returncode:
        info(f"kept {branch}: {deleted.stderr.strip()}")
    info(f"{path} is on {repo.default}" + ("" if deleted.returncode else f"; deleted {branch}"))
    tell_sessions(repo, f"it is now on {repo.default}")


def _land_branch_pr(repo: Repo, branch: str, args: argparse.Namespace) -> None:
    path = repo.main
    pr = pr_view(path, branch) if has_origin(repo) else None
    head = probe(path, "rev-parse", "HEAD").strip()
    if not (pr and pr.get("state") == "MERGED" and pr.get("headRefOid") == head):
        # A PR merged at this very commit needs no push: pushing could recreate a deleted remote branch.
        pr = land_pr(repo, Entry(branch, branch, path), args, args.mode)
    if args.dry_run or not pr:
        return
    if pr.get("state") == "MERGED":
        _switch_to_default(repo, branch, merged=True)
    elif args.mode == "green":
        info(f"{path} stays on {branch} until #{pr['number']} merges; rerun 'wt land --green' then to switch back to {repo.default}")
    else:
        info(f"{path} stays on {branch} while #{pr['number']} is open")


# ---------------------------------------------------------------------------


def _resume(repo: Repo, args: argparse.Namespace) -> None:
    path = repo.main
    if inspect(path, lambda: operation_in_progress(path)) != "rebase":
        die(f"no rebase in progress in {path}")
    if args.abort:
        run(["git", "-C", path, "rebase", "--abort"])
        info(f"aborted the rebase in {path}")
        return
    if run(["git", "-C", path, "rebase", "--continue"], check=False).returncode != 0:
        try:
            conflicts = conflicted(path)
        except ProbeError:
            conflicts = []
        die(f"rebase still has conflicts{': ' + ', '.join(conflicts) if conflicts else ''}")
    # Mid-rebase the checkout is detached, so which landing paused is only known again now.
    branch = root_branch(repo)
    if branch == repo.default:
        tell_sessions(repo, f"files moved under it when {repo.default} was rebased")
        _push(repo, f"origin/{repo.default}")
    elif branch:
        _finish_branch(repo, branch)
    else:
        die(f"{path} is still detached after the rebase; finish it by hand")
