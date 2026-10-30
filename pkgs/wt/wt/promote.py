"""Swapping branches through the primary checkout: promote and evict."""

from __future__ import annotations

import argparse
import json
import os
import time
from typing import Optional

from .commands import EVICTED_KEY, _conflicted, _default_checkout, _dirty_paths, current_branch
from .git import die, git, git_ok, info, is_within, run
from .repo import Repo, RepoLock, current_repo, registered_worktrees
from .status import Worktree, busy_pids, describe_pid, gather, resolve_row

# A build or activation reading the primary checkout must not see its files change mid-run.
BLOCKING_COMMANDS = {"nixos-rebuild", "darwin-rebuild", "home-manager", "nh", "nix-build", "nom"}
# `nix` blocks only for subcommands that read the tree; a `nix develop` or `nix repl` there can sit for days.
BLOCKING_NIX = {"build", "flake", "eval", "run", "fmt"}

# The git-path each in-progress operation leaves behind, and how to end it.
OPERATIONS = {
    "rebase-merge": "git rebase --continue, or git rebase --abort",
    "rebase-apply": "git rebase --continue / git am --continue, or --abort",
    "MERGE_HEAD": "git merge --continue, or git merge --abort",
    "CHERRY_PICK_HEAD": "git cherry-pick --continue, or git cherry-pick --abort",
    "REVERT_HEAD": "git revert --continue, or git revert --abort",
    "BISECT_LOG": "git bisect reset",
}

DIRTY_MODES = ("carry", "stash", "wip", "move")


def _operation(path: str) -> Optional[str]:
    for name, finish in OPERATIONS.items():
        found = git(path, "rev-parse", "--path-format=absolute", "--git-path", name, check=False).strip()
        if found and os.path.exists(found):
            return f"{name} in {path}: finish it first ({finish})"
    return None


def _process_name(pid: int) -> str:
    try:
        with open(f"/proc/{pid}/comm") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def _argv(pid: int) -> list[str]:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            return handle.read().decode(errors="replace").split("\0")
    except OSError:
        return []


def _blocking(pid: int) -> bool:
    name = _process_name(pid)
    # Matching any argument, not the first positional one, since global flags take values.
    return name in BLOCKING_COMMANDS or (name == "nix" and bool(BLOCKING_NIX.intersection(_argv(pid)[1:])))


def _blockers(path: str) -> list[int]:
    return [pid for pid in busy_pids(path) if _blocking(pid)]


# ---------------------------------------------------------------------------
# Shelving uncommitted work by stash sha, never by stack position


def _shelve(path: str, label: str) -> Optional[str]:
    """Stash every uncommitted change in `path`, untracked files included.

    Returns the stash commit's sha, or None when there was nothing to stash. The entry is found
    by a tag unique to this call, because other sessions push and pop the same shared stack.
    """
    if not git(path, "status", "--porcelain", check=False).strip():
        return None
    tag = f"wt {label} [{os.getpid()}.{time.time_ns()}]"
    run(["git", "-C", path, "stash", "push", "--include-untracked", "-m", tag])
    for line in git(path, "stash", "list", "--format=%H %gs", check=False).splitlines():
        sha, _, subject = line.partition(" ")
        if subject.endswith(tag):
            return sha
    die(f"stashed the changes in {path} but cannot find the entry '{tag}'; see git stash list")


def _drop(path: str, sha: str) -> None:
    for index, line in enumerate(git(path, "stash", "list", "--format=%H", check=False).splitlines()):
        if line.strip() == sha:
            run(["git", "-C", path, "stash", "drop", f"stash@{{{index}}}"], check=False)
            return


def _unshelve(path: str, sha: str) -> bool:
    """Apply stash `sha` in `path` and drop it; False (entry kept) when it does not apply cleanly."""
    if run(["git", "-C", path, "stash", "apply", "--index", sha], check=False).returncode != 0:
        # --index refuses when the staged half no longer applies; the changes may still, unstaged.
        if _conflicted(path) or run(["git", "-C", path, "stash", "apply", sha], check=False).returncode != 0:
            return False
    _drop(path, sha)
    return True


def _stash_paths(path: str, sha: str) -> set[str]:
    tracked = git(path, "stash", "show", "--name-only", sha, check=False).splitlines()
    # The untracked files of a `push -u` stash live in its third parent.
    untracked = git(path, "show", "--format=", "--name-only", f"{sha}^3", check=False).splitlines()
    return {line for line in [*tracked, *untracked] if line}


# ---------------------------------------------------------------------------
# Planning


def _fetch_origin(repo: Repo) -> None:
    if run(["git", "--git-dir", repo.common, "remote", "get-url", "origin"], check=False).returncode != 0:
        return
    proc = run(["timeout", "10", "git", "-C", repo.main, "fetch", "--quiet", "origin", repo.default], check=False)
    if proc.returncode != 0:
        info(f"fetch of origin/{repo.default} failed; using the origin ref already here")


def _count(path: str, spec: str) -> int:
    out = git(path, "rev-list", "--count", spec, check=False).strip()
    return int(out) if out.isdigit() else 0


def _bases(repo: Repo, branch: str) -> dict:
    """What a rebase onto each base would bring in: commits the branch lacks, per base that exists."""
    bases: dict = {}
    for key, ref in (("local", repo.default), ("origin", f"origin/{repo.default}")):
        if git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"):
            bases[key] = {"ref": ref, "behind": _count(repo.main, f"{branch}..{ref}")}
    if "local" in bases and "origin" in bases:
        bases["unpushed"] = _count(repo.main, f"origin/{repo.default}..{repo.default}")
    return bases


def _home(repo: Repo, branch: str) -> str:
    return os.path.join(repo.directory, branch.replace("/", "-"))


def _primary_row(rows: list[Worktree]) -> Worktree:
    for row in rows:
        if row.is_main:
            return row
    die("no primary checkout found")


def _occupant(repo: Repo, primary: Worktree) -> dict:
    """What sits in the primary checkout and what has to happen to it before another branch moves in."""
    branch = primary.branch
    stray = primary.state != "clean" and branch in ("", repo.default)
    evicts = branch not in ("", repo.default)
    return {
        "branch": branch or None,
        "state": primary.state,
        # Uncommitted changes on the default branch (or a detached HEAD) belong to no feature branch,
        # so where they go is the caller's choice.
        "strayEdits": stray,
        "evicts": branch if evicts else None,
        "evictTo": _home(repo, branch) if evicts else None,
        "operation": _operation(primary.path),
        "busy": [{"pid": pid, "name": _process_name(pid) or describe_pid(pid)} for pid in busy_pids(primary.path)],
        "blocking": [describe_pid(pid) for pid in _blockers(primary.path)],
    }


def _print_plan(plan: dict) -> None:
    lines = [f"{plan['verb']} {plan['branch']} → {plan['primary']}"]
    occupant = plan["occupant"]
    lines.append(f"primary  {occupant['branch'] or '(detached)'} · {occupant['state']}")
    if occupant["evicts"]:
        lines.append(f"evicts   {occupant['evicts']} → {occupant['evictTo']}, uncommitted changes with it")
    if occupant["strayEdits"]:
        lines.append(f"edits    uncommitted changes on {occupant['branch'] or 'a detached HEAD'}: pass --dirty {'|'.join(plan['dirtyModes'])}")
    if occupant["operation"]:
        lines.append(f"refuses  {occupant['operation']}")
    for blocker in occupant["blocking"]:
        lines.append(f"refuses  {blocker} is building from the primary checkout")
    if occupant["busy"]:
        counts: dict[str, int] = {}
        for item in occupant["busy"]:
            counts[item["name"]] = counts.get(item["name"], 0) + 1
        lines.append("busy     " + ", ".join(name if n == 1 else f"{name} ×{n}" for name, n in counts.items()))
    if plan["verb"] == "evict" and not occupant["evicts"] and not occupant["strayEdits"]:
        lines.append("nothing  the primary checkout has nothing to move out")
    source = plan.get("source")
    if source:
        lines.append(f"source   {source['path']} · {source['state']} · {'kept detached (in use)' if source['keepDir'] else 'removed, branch kept'}")
    bases = plan.get("bases") or {}
    for key in ("local", "origin"):
        if key in bases:
            behind = bases[key]["behind"]
            lines.append(f"base     {bases[key]['ref']}: " + (f"{behind} commit(s) the branch lacks" if behind else "already contained"))
    if bases.get("unpushed"):
        lines.append(f"base     local {plan['default']} has {bases['unpushed']} commit(s) not on origin")
    print("\n".join(lines))


# ---------------------------------------------------------------------------
# The swap


def _require_dirty_choice(occupant: dict, dirty: Optional[str], name: Optional[str], *, carry_ok: bool) -> None:
    if not occupant["strayEdits"]:
        return
    modes = [mode for mode in DIRTY_MODES if carry_ok or mode != "carry"]
    if not dirty:
        die(
            f"the primary checkout has uncommitted changes on {occupant['branch'] or 'a detached HEAD'}; "
            f"choose where they go with --dirty {'|'.join(modes)}"
        )
    if dirty not in modes:
        die(f"--dirty {dirty} does not apply here; choose one of {', '.join(modes)}")
    if dirty in ("wip", "move") and not name:
        die(f"--dirty {dirty} needs --name <branch> for the new branch")


def _require_ready(repo: Repo, occupant: dict, new_branch: Optional[str], evicted: Optional[str]) -> None:
    if occupant["operation"]:
        die(occupant["operation"])
    if occupant["blocking"]:
        die(f"{', '.join(occupant['blocking'])} is running in {repo.main}; wait for it to finish")
    if new_branch and git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"refs/heads/{new_branch}"):
        die(f"branch '{new_branch}' already exists; pick another --name")
    if evicted:
        home = _home(repo, evicted)
        registered = {item["path"]: item for item in registered_worktrees(repo.common)}
        if os.path.exists(home) and (home not in registered or registered[home]["branch"]):
            die(f"{home} already exists and is not a detached worktree that {evicted} could return to")


def _settle_stray(repo: Repo, occupant: dict, dirty: Optional[str], name: Optional[str]) -> tuple[Optional[str], list[str]]:
    """Deal with uncommitted changes on the default branch; returns the branch to evict, if any, and report lines."""
    if not occupant["strayEdits"] or dirty == "carry":
        return None, []
    if dirty == "stash":
        sha = _shelve(repo.main, f"stray {occupant['branch'] or 'detached'} edits")
        return None, [f"stashed the uncommitted changes of {repo.main} as {sha}; git stash apply {sha} brings them back"]
    run(["git", "-C", repo.main, "switch", "--quiet", "-c", name])
    run(["git", "-C", repo.main, "add", "-A"])
    # Hooks would format or reject work that was never meant to be committed yet.
    run(["git", "-C", repo.main, "commit", "--quiet", "--no-verify", "-m", f"wip: uncommitted changes left on {occupant['branch'] or 'a detached HEAD'}"])
    if dirty == "wip":
        return None, [f"committed the uncommitted changes as wip on new branch {name} (no worktree)"]
    return name, []


def _evict(repo: Repo, branch: str, shelf: Optional[str]) -> list[str]:
    """Give `branch` its worktree back, with the uncommitted changes shelved as `shelf`."""
    home = _home(repo, branch)
    if os.path.isdir(home):
        run(["git", "-C", home, "switch", "--quiet", branch])
    else:
        run(["git", "-C", repo.main, "worktree", "add", "--quiet", home, branch])
    report = [f"evicted {branch} to {home}"]
    if shelf and not _unshelve(home, shelf):
        report.append(f"its uncommitted changes did not apply cleanly in {home}; they are kept as stash {shelf}")
    return report


def _swap(
    repo: Repo,
    primary: Worktree,
    incoming: str,
    source: Optional[Worktree],
    *,
    dirty: Optional[str],
    name: Optional[str],
    onto: Optional[str],
) -> dict:
    """Put `incoming` into the primary checkout, sending what was there to its own worktree.

    `source` is the worktree `incoming` comes from (None for the default branch). Every refusal
    happens before the first change; later failures name the stash entries holding the work.
    """
    occupant = _occupant(repo, primary)
    _require_dirty_choice(occupant, dirty, name, carry_ok=source is not None)
    stray = occupant["strayEdits"]
    new_branch = name if stray and dirty in ("wip", "move") else None
    _require_ready(repo, occupant, new_branch, occupant["evicts"] or (name if stray and dirty == "move" else None))
    report: list[str] = []

    source_shelf = _shelve(source.path, f"promote {incoming}") if source else None

    def put_back(message: str) -> None:
        if source and source_shelf and not _unshelve(source.path, source_shelf):
            message += f"\n  its uncommitted changes are kept as stash {source_shelf}"
        die(message)

    if source and onto:
        ref = repo.default if onto == "local" else f"origin/{repo.default}"
        info(f"rebasing {incoming} onto {ref}")
        if run(["git", "-C", source.path, "rebase", "--quiet", ref], check=False).returncode != 0:
            conflicts = _conflicted(source.path)
            run(["git", "-C", source.path, "rebase", "--abort"], check=False)
            detail = f" ({', '.join(conflicts)})" if conflicts else ""
            put_back(f"rebasing {incoming} onto {ref} conflicts{detail}; aborted, nothing moved")
        report.append(f"rebased {incoming} onto {ref}")

    if occupant["strayEdits"] and dirty == "carry":
        incoming_paths = set(git(repo.main, "diff", "--name-only", "HEAD", incoming, check=False).splitlines())
        if source_shelf:
            incoming_paths |= _stash_paths(source.path, source_shelf)
        clash = sorted(_dirty_paths(repo.main) & incoming_paths)
        if clash:
            put_back(f"cannot carry the uncommitted changes in {repo.main}: {incoming} also changes {', '.join(clash)}; choose another --dirty")

    evicted, lines = _settle_stray(repo, occupant, dirty, name)
    report.extend(lines)
    occupant_shelf = None

    def stranded(message: str) -> None:
        kept = [sha for sha in (source_shelf, occupant_shelf) if sha]
        die(message + (f"\n  uncommitted work is kept as stash {', '.join(kept)}" if kept else ""))

    if occupant["evicts"]:
        evicted = occupant["evicts"]
        occupant_shelf = _shelve(repo.main, f"evict {evicted}")

    keep_dir = False
    if source:
        keep_dir = bool(busy_pids(source.path)) or is_within(os.getcwd(), os.path.realpath(source.path))
        if keep_dir:
            run(["git", "-C", source.path, "switch", "--quiet", "--detach"])
            report.append(f"left {source.path} detached: something still works there; wt clean removes it later")
        else:
            proc = run(["git", "-C", repo.main, "worktree", "remove", source.path], check=False)
            if proc.returncode != 0:
                stranded(f"could not remove {source.path}: {proc.stderr.strip()}")
            report.append(f"removed {source.path}; branch {incoming} kept")

    proc = run(["git", "-C", repo.main, "switch", "--quiet", incoming], check=False)
    if proc.returncode != 0:
        stranded(f"could not switch {repo.main} to {incoming}: {proc.stderr.strip()}")
    report.append(f"{repo.main} is on {incoming}")
    if source_shelf and not _unshelve(repo.main, source_shelf):
        report.append(f"the uncommitted changes of {incoming} did not apply cleanly; they are kept as stash {source_shelf}")
    if evicted:
        report.extend(_evict(repo, evicted, occupant_shelf))

    return {
        "branch": incoming,
        "primary": repo.main,
        "evicted": evicted,
        "evictedTo": _home(repo, evicted) if evicted else None,
        "sourceKept": source.path if source and keep_dir else None,
        "report": report,
    }


def _emit(result: dict, as_json: bool) -> None:
    for line in result["report"]:
        info(line)
    if as_json:
        print(json.dumps(result, indent=2))


# ---------------------------------------------------------------------------
# Verbs


def cmd_promote(args: argparse.Namespace) -> None:
    repo = current_repo()
    with RepoLock(repo):
        rows = gather(repo)
        source = resolve_row(repo, args.target or ".", rows)
        if source.is_main:
            die("name the worktree to promote; this is the primary checkout")
        if not source.registered or source.detached or not source.branch:
            die(f"'{source.name}' has no branch to promote")
        if source.branch == repo.default:
            die(f"'{source.name}' is on the default branch; the primary checkout is where that belongs")
        if source.locked:
            die(f"'{source.name}' is locked. Run: git -C '{repo.main}' worktree unlock '{source.path}'")
        if _operation(source.path):
            die(_operation(source.path))
        primary = _primary_row(rows)
        if args.dry_run or args.onto == "origin":
            _fetch_origin(repo)
        if args.dry_run:
            plan = {
                "verb": "promote",
                "branch": source.branch,
                "primary": repo.main,
                "default": repo.default,
                "occupant": _occupant(repo, primary),
                "source": {
                    "path": source.path,
                    "state": source.state,
                    # The caller's cwd is left out: a session leaves the worktree before the real run.
                    "keepDir": bool(busy_pids(source.path)),
                },
                "bases": _bases(repo, source.branch),
                "dirtyModes": list(DIRTY_MODES),
            }
            if args.json:
                print(json.dumps(plan, indent=2))
            else:
                _print_plan(plan)
            return
        result = _swap(repo, primary, source.branch, source, dirty=args.dirty, name=args.name, onto=args.onto)
        if result["evicted"]:
            run(["git", "-C", repo.main, "config", "--local", EVICTED_KEY, result["evicted"]])
        else:
            run(["git", "-C", repo.main, "config", "--local", "--unset", EVICTED_KEY], check=False)
        _emit(result, args.json)


def cmd_evict(args: argparse.Namespace) -> None:
    repo = current_repo()
    with RepoLock(repo):
        rows = gather(repo)
        primary = _primary_row(rows)
        holder = _default_checkout(repo)
        if holder and holder != repo.main:
            die(f"{repo.default} is checked out in {holder}, so the primary checkout cannot return to it")
        occupant = _occupant(repo, primary)
        if args.dry_run:
            plan = {
                "verb": "evict",
                "branch": repo.default,
                "primary": repo.main,
                "default": repo.default,
                "occupant": occupant,
                "dirtyModes": [mode for mode in DIRTY_MODES if mode != "carry"],
                "evicted": git(repo.main, "config", "--local", "--get", EVICTED_KEY, check=False).strip() or None,
            }
            if args.json:
                print(json.dumps(plan, indent=2))
            else:
                _print_plan(plan)
            return
        if not occupant["evicts"] and not occupant["strayEdits"]:
            die(f"the primary checkout is already on {current_branch(repo.main) or 'a detached HEAD'} with nothing to move out")
        previous = git(repo.main, "config", "--local", "--get", EVICTED_KEY, check=False).strip() or None
        result = _swap(repo, primary, repo.default, None, dirty=args.dirty, name=args.name, onto=None)
        run(["git", "-C", repo.main, "config", "--local", "--unset", EVICTED_KEY], check=False)
        # The branch an earlier promote pushed out, so whoever works on it can be told the primary is free.
        result["previouslyEvicted"] = previous
        _emit(result, args.json)
