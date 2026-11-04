"""wt land: rebase a worktree onto the default branch and fast-forward the default branch onto it."""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from typing import Optional

from .commands import close_entry, occupants
from .gh import GhError, checks_state, gh, has_origin, merged_heads, pr_view, requires_checks, stack
from .git import ProbeError, die, git, git_ok, info, inspect, is_within, probe, run
from .procs import busy_pids, describe_pid
from .repo import Repo, RepoLock, current_repo, registered_worktrees
from .worktrees import Entry, ahead, conflicted, dirty, entries, is_wip, operation_in_progress, resolve


def _dirty_paths(path: str) -> set[str]:
    """Every path whose working-tree or index state a fast-forward could disturb.

    `--untracked-files=all` and a probe that raises keep a failed or hidden answer from reading as
    clean, which would fast-forward over work nobody committed.
    """
    fields = probe(path, "status", "--porcelain", "--untracked-files=all", "-z").split("\0")
    names: set[str] = set()
    index = 0
    while index < len(fields):
        entry = fields[index]
        index += 1
        if len(entry) > 3:
            names.add(entry[3:])
            # A rename carries its source path as the next field.
            if entry[0] in "RC" and index < len(fields) and fields[index]:
                names.add(fields[index])
                index += 1
    return names


def _incoming_paths(repo: Repo, branch: str) -> set[str]:
    """Paths `branch` changes against the default branch; an empty diff is a real answer."""
    out = probe(repo.main, "diff", "--name-only", f"{repo.default}...{branch}", "--")
    return {line for line in out.splitlines() if line}


def _conflicts(path: str) -> list[str]:
    """Conflict names for a message; empty when they cannot be listed, so the pause is still reported."""
    try:
        return conflicted(path)
    except ProbeError:
        return []


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
    dirty_paths = inspect(checkout, lambda: _dirty_paths(checkout))
    if not dirty_paths:
        return
    clash = sorted(dirty_paths & inspect(branch, lambda: _incoming_paths(repo, branch)))
    if not clash:
        info(f"{checkout} has uncommitted changes in {len(dirty_paths)} path(s) this branch does not touch; leaving them")
        return
    die(
        f"{checkout} has uncommitted changes to {', '.join(clash)}, which {branch} also changes, "
        "so git cannot fast-forward over them.\n"
        f"  Yours: commit or stash them in {checkout} first.\n"
        "  Another session's: leave them alone and land once that checkout is clean."
    )


def rebase(entry: Entry, onto: str, *, abort_on_conflict: bool, update_refs: bool = False) -> None:
    """Rebase `entry` onto `onto`, moving stacked branches along with `update_refs`; a conflict exits, paused or aborted."""
    path = entry.path or ""
    info(f"rebasing {entry.branch} onto {onto}")
    extra = ["--update-refs"] if update_refs else []
    if run(["git", "-C", path, "rebase", "--quiet", *extra, onto], check=False).returncode == 0:
        return
    conflicts = _conflicts(path)
    print(f"wt: rebase conflict{': ' + ', '.join(conflicts) if conflicts else ''}", file=sys.stderr)
    if abort_on_conflict:
        run(["git", "-C", path, "rebase", "--abort"], check=False)
        die(f"aborted the rebase; {path} is back on {entry.branch}")
    die(
        f"rebase paused in {path}; resolve the conflicts, then "
        f"'wt land --continue {entry.name}' or 'wt land --abort {entry.name}'"
    )


def _fast_forward_default(repo: Repo, entry: Entry) -> None:
    count = inspect(f"'{entry.name}'", lambda: ahead(repo, entry.branch))
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
    try:
        changed = _incoming_paths(repo, entry.branch)
    except ProbeError:
        changed = set()
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
    operation = inspect(f"'{entry.name}'", lambda: operation_in_progress(path))
    if operation == "rebase":
        die(f"a rebase is in progress in {path}; finish it with 'wt land --continue' or 'wt land --abort'")
    if operation:
        die(f"'{entry.name}' is in the middle of a {operation}; finish or abort it first")
    if inspect(f"'{entry.name}'", lambda: dirty(path)):
        die(f"'{entry.name}' has uncommitted changes; commit them inside the worktree first")
    if inspect(f"'{entry.name}'", lambda: is_wip(path, "HEAD")):
        die(f"the tip of {entry.branch} is a wip commit from 'wt close'; turn it into a real commit first")


def land_local(repo: Repo, entry: Entry, args: argparse.Namespace) -> None:
    layered = stack(entry.path or "") if has_origin(repo) else None
    if layered:
        # Every layer lands at once: rebase the top, and --update-refs carries the layers under it.
        top = layered["branches"][-1]["name"]
        if top != entry.branch and not args.dry_run:
            run(["git", "-C", entry.path or "", "switch", "--quiet", top])
        entry = Entry(entry.name, top, entry.path, entry.locked)
    if not inspect(f"'{entry.name}'", lambda: ahead(repo, entry.branch)):
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
    rebase(entry, repo.default, abort_on_conflict=args.abort_on_conflict, update_refs=bool(layered))
    _fast_forward_default(repo, entry)
    close_after_landing(repo, entry)


# ---------------------------------------------------------------------------
# Through GitHub


def _duration(value: str) -> float:
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([smh]?)\s*", value)
    if not match:
        die(f"bad duration '{value}'; use e.g. 30s, 5m, 2h")
    return float(match.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2)]


def _gh(path: str, *args: str) -> str:
    try:
        return gh(path, *args)
    except GhError as error:
        die(f"gh {' '.join(args[:2])} failed: {error}")


def _publish(repo: Repo, entry: Entry) -> None:
    """Push the branch, rebased onto origin/<default> first while it has never been pushed."""
    path = entry.path or ""
    branch = entry.branch
    run(["timeout", "20", "git", "-C", path, "fetch", "--quiet", "origin", repo.default], check=False)
    upstream = f"origin/{repo.default}"
    if not git_ok(path, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{branch}"):
        # Commits only local <default> has stay out of the PR; they are not this branch's.
        info(f"rebasing {branch} onto {upstream}")
        if run(["git", "-C", path, "rebase", "--quiet", "--onto", upstream, repo.default], check=False).returncode:
            run(["git", "-C", path, "rebase", "--abort"], check=False)
            die(
                f"{branch} does not rebase cleanly onto {upstream}: it conflicts, or depends on commits only "
                f"local {repo.default} has. Push {repo.default} first, or land locally with 'wt land {entry.name}'."
            )
    else:
        proc = run(["git", "-C", path, "merge-base", "--is-ancestor", f"origin/{branch}", branch], check=False)
        if proc.returncode == 1:
            die(f"origin/{branch} has diverged from {branch}; pushing would need a force push, which wt never does")
        if proc.returncode != 0:
            die(f"could not compare {branch} with origin/{branch}: {(proc.stderr or proc.stdout).strip()}")
    if run(["git", "-C", path, "push", "--quiet", "--set-upstream", "origin", branch], check=False).returncode:
        die(f"git push of {branch} failed")


def _open_pr(repo: Repo, entry: Entry, args: argparse.Namespace, draft: bool) -> dict:
    """The branch's open PR, created or switched to the asked draft state."""
    path = entry.path or ""
    pr = pr_view(path, entry.branch)
    if pr and pr["state"] == "CLOSED":
        die(f"PR #{pr['number']} for {entry.branch} was closed unmerged; reopen it on GitHub first")
    if pr is None:
        create = ["pr", "create", "--base", repo.default, "--head", entry.branch]
        if args.title or args.body_file:
            title = args.title or git(path, "log", "-1", "--format=%s").strip()
            create += ["--title", title]
            create += ["--body-file", args.body_file] if args.body_file else ["--body", ""]
        else:
            create.append("--fill")
        _gh(path, *create, *(["--draft"] if draft else []))
        pr = pr_view(path, entry.branch)
        if pr is None:
            die(f"gh created no PR for {entry.branch}")
        info(f"opened {'draft ' if draft else ''}PR #{pr['number']}: {pr['url']}")
    elif pr["state"] == "OPEN":
        if draft and not pr.get("isDraft"):
            _gh(path, "pr", "ready", "--undo", str(pr["number"]))
        elif not draft and pr.get("isDraft"):
            _gh(path, "pr", "ready", str(pr["number"]))
        info(f"PR #{pr['number']} is up to date: {pr['url']}")
    return pr


def _wait_for_checks(path: str, numbers: list[int], timeout: float) -> None:
    """Return once every PR's checks pass (or it has none); exit on a failure or the timeout."""
    deadline = time.monotonic() + timeout
    poll = float(os.environ.get("WT_GH_POLL") or 15)
    said = ""
    while True:
        pending = []
        for number in numbers:
            pr = pr_view(path, str(number)) or {}
            if pr.get("state") == "CLOSED":
                die(f"PR #{number} was closed")
            if pr.get("mergeable") == "CONFLICTING":
                die(f"PR #{number} conflicts with its base; rebase it, push, and rerun")
            state, failing = checks_state(pr)
            if state == "fail":
                die(f"checks failing on #{number}: {', '.join(failing)}; fix them, commit, and rerun 'wt land --green'")
            if state == "pending" and pr.get("state") != "MERGED":
                pending.append(number)
        if not pending:
            return
        line = f"waiting for checks on {', '.join(f'#{n}' for n in pending)}"
        if line != said:
            info(line)
            said = line
        if time.monotonic() >= deadline:
            die("checks still pending; rerun 'wt land --green' to keep waiting")
        time.sleep(poll)


def _report_behind(repo: Repo) -> None:
    run(["timeout", "20", "git", "-C", repo.main, "fetch", "--quiet", "origin", repo.default], check=False)
    try:
        behind = ahead(repo, f"origin/{repo.default}")
    except ProbeError:
        # A freshness note is not worth failing a merge that already happened.
        return
    if behind:
        info(f"local {repo.default} is {behind} commit(s) behind origin/{repo.default}; "
             f"git -C {default_checkout(repo) or repo.main} pull --ff-only")


def land_pr(repo: Repo, entry: Entry, args: argparse.Namespace, mode: str) -> None:
    """Land through GitHub: `draft` and `pr` open the PR, `green` also merges it once checks pass."""
    path = entry.path or ""
    if not has_origin(repo):
        die("there is no origin remote; land locally with 'wt land'")
    layered = stack(path)
    if layered:
        _land_stack(repo, entry, args, mode, layered)
        return
    if args.dry_run:
        info(f"would push {entry.branch} and open a {'draft ' if mode == 'draft' else ''}PR into {repo.default}")
        return
    _publish(repo, entry)
    unpublished = inspect(
        f"'{entry.name}'", lambda: probe(path, "rev-list", f"origin/{repo.default}..{entry.branch}").strip()
    )
    if not inspect(f"'{entry.name}'", lambda: ahead(repo, entry.branch)) or not unpublished:
        info(f"{entry.branch} has nothing that is not already in {repo.default}; no PR to open")
        close_after_landing(repo, entry)
        return
    pr = _open_pr(repo, entry, args, draft=mode == "draft")
    print(pr["url"])
    if mode == "green" and pr["state"] == "OPEN":
        sha = git(path, "rev-parse", "HEAD").strip()
        if requires_checks(path, repo.default):
            _gh(path, "pr", "merge", str(pr["number"]), "--auto", "--rebase", "--match-head-commit", sha)
            info(f"GitHub merges #{pr['number']} once its required checks pass")
        else:
            _wait_for_checks(path, [pr["number"]], _duration(args.timeout))
            _gh(path, "pr", "merge", str(pr["number"]), "--rebase", "--match-head-commit", sha)
            info(f"merged #{pr['number']} into {repo.default}")
            merged_heads.cache_clear()
            _report_behind(repo)
    close_after_landing(repo, entry)


def _land_stack(repo: Repo, entry: Entry, args: argparse.Namespace, mode: str, layered: dict) -> None:
    path = entry.path or ""
    names = [branch["name"] for branch in layered.get("branches", [])]
    if args.dry_run:
        info(f"would submit the stack {' <- '.join(names)} with gh stack")
        return
    _gh(path, "stack", "submit", "--auto", "--remote", "origin", *([] if mode == "draft" else ["--open"]))
    info(f"submitted the stack {' <- '.join(names)}")
    if mode == "green":
        # A stack merges all at once and gh stack has no auto-merge, so this waits for every layer's checks.
        layered = stack(path) or layered
        prs = [b["pr"]["number"] for b in layered.get("branches", []) if (b.get("pr") or {}).get("state") == "OPEN"]
        if prs:
            _wait_for_checks(path, prs, _duration(args.timeout))
            _gh(path, "stack", "merge", str(prs[-1]), "--yes", "--rebase")
            info(f"merged the stack up to #{prs[-1]} into {repo.default}")
            merged_heads.cache_clear()
            _report_behind(repo)
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
        conflicts = _conflicts(path)
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
        if args.mode:
            land_pr(repo, entry, args, args.mode)
        else:
            land_local(repo, entry, args)
