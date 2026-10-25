#!/usr/bin/env python3
"""Describe, open, watch and merge the pull request for the current branch.

Reads state from git and `gh` and prints it in a form an agent can act on. It
never lands locally, never touches the default branch, and never merges without
re-checking the state it is about to merge.

Exit codes: 0 ok, 1 refused (reason printed), 2 environment (no gh/auth/remote),
3 conflicts with the base, 10 approved and green, 11 changes requested, 12 checks
failing, 13 closed or merged elsewhere, 14 timeout.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

EXIT_OK = 0
EXIT_REFUSED = 1
EXIT_ENV = 2
EXIT_CONFLICT = 3
EXIT_APPROVED = 10
EXIT_CHANGES = 11
EXIT_CHECKS = 12
EXIT_GONE = 13
EXIT_TIMEOUT = 14

ENV = {**os.environ, "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"}

PR_FIELDS = (
    "number,state,isDraft,url,reviewDecision,mergeable,mergeStateStatus,"
    "headRefName,baseRefName,headRefOid,mergeCommit,statusCheckRollup"
)


class GhError(Exception):
    """`gh` failed; the message is the CLI's own stderr."""


def die(message: str, code: int = EXIT_ENV) -> "SystemExit":
    print(f"pr: {message}", file=sys.stderr)
    raise SystemExit(code)


def note(message: str) -> None:
    print(f"pr: {message}", file=sys.stderr)


def git(*args: str, check: bool = True) -> str:
    proc = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and proc.returncode != 0:
        die(f"git {args[0]} failed: {proc.stderr.strip() or proc.stdout.strip()}", EXIT_REFUSED)
    return proc.stdout.strip()


def git_ok(*args: str) -> tuple[bool, str]:
    proc = subprocess.run(["git", *args], capture_output=True, text=True)
    return proc.returncode == 0, proc.stdout.strip()


def gh(*args: str) -> str:
    proc = subprocess.run(["gh", *args], capture_output=True, text=True, env=ENV)
    if proc.returncode != 0:
        raise GhError(proc.stderr.strip() or proc.stdout.strip())
    return proc.stdout.strip()


def require_tools(*tools: str) -> None:
    missing = [tool for tool in tools if shutil.which(tool) is None]
    if missing:
        die(f"missing {' '.join(missing)} on PATH", EXIT_ENV)


def require_gh() -> None:
    require_tools("gh")
    proc = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True, env=ENV)
    if proc.returncode != 0:
        die("gh is not authenticated; run 'gh auth login'", EXIT_ENV)


def has_remote(name: str = "origin") -> bool:
    ok, _ = git_ok("remote", "get-url", name)
    return ok


def branch() -> str:
    name = git("rev-parse", "--abbrev-ref", "HEAD")
    if name == "HEAD":
        die("detached HEAD; check out the branch first", EXIT_REFUSED)
    return name


def default_branch() -> str:
    ok, ref = git_ok("symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
    if ok and ref:
        return ref.rsplit("/", 1)[-1]
    for candidate in ("main", "master"):
        if git_ok("rev-parse", "--verify", "--quiet", f"origin/{candidate}")[0]:
            return candidate
    for candidate in ("main", "master"):
        if git_ok("rev-parse", "--verify", "--quiet", f"refs/heads/{candidate}")[0]:
            return candidate
    die("cannot determine the default branch", EXIT_ENV)


def upstream() -> str | None:
    ok, ref = git_ok("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    return ref if ok and ref else None


def divergence(left: str, right: str) -> tuple[int, int]:
    """Commits only in `left`, then commits only in `right`."""
    ok, out = git_ok("rev-list", "--left-right", "--count", f"{left}...{right}")
    if not ok or not out:
        return (0, 0)
    behind, ahead = out.split()
    return (int(behind), int(ahead))


def fetch_if_stale(default: str, max_age: int = 900) -> None:
    """Refresh origin/<default> when the last fetch is old; a failed fetch only warns."""
    ok, path = git_ok("rev-parse", "--path-format=absolute", "--git-path", "FETCH_HEAD")
    age = time.time() - os.stat(path).st_mtime if ok and os.path.exists(path) else None
    if age is not None and age < max_age:
        return
    proc = subprocess.run(
        ["timeout", "5", "git", "fetch", "--quiet", "origin", default],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        note(f"fetch of origin/{default} failed; reporting possibly stale refs")


def commits(base: str, ref: str = "HEAD") -> list[dict[str, str]]:
    proc = subprocess.run(
        ["git", "log", "--format=%h%x1f%s", f"{base}..{ref}"], capture_output=True, text=True
    )
    if proc.returncode != 0:
        return []
    out = []
    for line in proc.stdout.splitlines():
        sha, _, subject = line.partition("\x1f")
        out.append({"sha": sha, "subject": subject})
    return out


def dirty_paths() -> list[str]:
    proc = subprocess.run(["git", "status", "--porcelain", "-z"], capture_output=True, text=True)
    fields = proc.stdout.split("\0")
    paths: list[str] = []
    index = 0
    while index < len(fields):
        entry = fields[index]
        index += 1
        if len(entry) < 4:
            continue
        paths.append(entry[3:])
        # A rename or copy is followed by the source path in its own field.
        if entry[0] in "RC":
            index += 1
    return paths


def pr_for(ref: str) -> dict | None:
    try:
        return json.loads(gh("pr", "view", ref, "--json", PR_FIELDS))
    except GhError as error:
        if "no pull requests found" in str(error).lower():
            return None
        raise


def check_rollup(pr: dict | None) -> dict:
    """Summarise statusCheckRollup into passed/failing/pending names."""
    rollup = (pr or {}).get("statusCheckRollup") or []
    passed, failing, pending = [], [], []
    for entry in rollup:
        name = entry.get("name") or entry.get("context") or "check"
        if entry.get("__typename") == "StatusContext":
            state = (entry.get("state") or "").upper()
            if state == "SUCCESS":
                passed.append(name)
            elif state in ("PENDING", ""):
                pending.append(name)
            else:
                failing.append(name)
            continue
        status = (entry.get("status") or "").upper()
        conclusion = (entry.get("conclusion") or "").upper()
        if status and status != "COMPLETED":
            pending.append(name)
        elif conclusion in ("SUCCESS", "NEUTRAL", "SKIPPED"):
            passed.append(name)
        elif conclusion:
            failing.append(name)
        else:
            pending.append(name)
    state = "none"
    if failing:
        state = "fail"
    elif pending:
        state = "pending"
    elif passed:
        state = "pass"
    return {"state": state, "passed": passed, "failing": failing, "pending": pending}


def checks_line(rollup: dict) -> str:
    if rollup["state"] == "none":
        return "none"
    parts = []
    if rollup["passed"]:
        parts.append(f"{len(rollup['passed'])} passed")
    if rollup["failing"]:
        parts.append(f"{len(rollup['failing'])} failing: {', '.join(rollup['failing'])}")
    if rollup["pending"]:
        parts.append(f"{len(rollup['pending'])} pending: {', '.join(rollup['pending'])}")
    return " · ".join(parts)


def collect(ref: str = "HEAD") -> dict:
    """Everything status and watch need, as plain data.

    `divergence()` counts commits only in its first argument first, so
    `local.ahead` is what `<default>` has that `origin/<default>` does not.
    """
    name = branch() if ref == "HEAD" else ref
    default = default_branch()
    fetched = has_remote()
    if fetched:
        fetch_if_stale(default)
    base = f"origin/{default}" if fetched else default
    branch_behind, branch_ahead = divergence(base, ref)
    pushed = fetched and git_ok("rev-parse", "--verify", "--quiet", f"origin/{name}")[0]
    remote = {"ahead": None, "behind": None}
    if pushed:
        remote_behind, remote_ahead = divergence(f"origin/{name}", ref)
        remote = {"ahead": remote_ahead, "behind": remote_behind}
    local = {"ahead": None, "behind": None}
    if fetched:
        local_ahead, local_behind = divergence(default, f"origin/{default}")
        local = {"ahead": local_ahead, "behind": local_behind}
    pr = None
    if fetched:
        require_gh()
        pr = pr_for(name)
    return {
        "branch": name,
        "default": default,
        "base": base,
        "tracking": upstream(),
        "pushed": pushed,
        "remote": remote,
        "branch_ahead": branch_ahead,
        "branch_behind": branch_behind,
        "local": local,
        "commits": commits(base, ref),
        "dirty": dirty_paths() if ref == "HEAD" else [],
        "pr": pr,
        "checks": check_rollup(pr),
    }


def cmd_status(args: argparse.Namespace) -> int:
    state = collect(args.branch or "HEAD")
    if args.json:
        print(json.dumps(state, indent=2))
        return EXIT_OK
    pr = state["pr"]
    local = state["local"]
    print(f"branch   {state['branch']} → {state['base']}")
    print(f"ahead    {state['branch_ahead']} ahead / {state['branch_behind']} behind {state['base']}")
    if local["ahead"] is not None:
        print(f"local    {state['default']} {local['ahead']} ahead / {local['behind']} behind origin/{state['default']}")
    tracking = state["tracking"] or "none"
    pushed = f"origin/{state['branch']}" if state["pushed"] else "not pushed"
    print(f"pushed   {pushed} (tracking {tracking})")
    print(f"commits  {len(state['commits'])}")
    for commit in state["commits"]:
        print(f"  {commit['sha']} {commit['subject']}")
    if pr is None:
        print("pr       none")
    else:
        draft = " (draft)" if pr.get("isDraft") else ""
        review = pr.get("reviewDecision") or "no review yet"
        print(f"pr       #{pr['number']} {pr['state']}{draft} · {review} · {pr.get('mergeable', 'unknown')}")
        print(f"url      {pr['url']}")
    print(f"checks   {checks_line(state['checks'])}")
    print(f"dirty    {'clean' if not state['dirty'] else str(len(state['dirty'])) + ' path(s)'}")
    return EXIT_OK


def push_branch(name: str, remote: str = "origin") -> None:
    proc = subprocess.run(["git", "push", "--set-upstream", remote, name], capture_output=True, text=True)
    if proc.returncode != 0:
        die(f"push of {name} failed: {proc.stderr.strip()}", EXIT_REFUSED)


def cmd_open(args: argparse.Namespace) -> int:
    name = branch()
    default = default_branch()
    if not has_remote():
        die("no origin remote", EXIT_ENV)
    require_gh()
    behind, ahead = divergence(default, f"origin/{default}")
    if ahead:
        note(
            f"local {default} is {ahead} commits ahead of origin/{default}; re-parent with "
            f"'git rebase --onto origin/{default} {default} {name}' or those commits enter this PR"
        )
    existing = pr_for(name)
    if existing is not None:
        number = existing["number"]
        state = existing["state"]
        if state != "OPEN":
            die(f"PR #{number} is {state}; reopen it instead of opening another", EXIT_REFUSED)
        gh("pr", "edit", str(number), "--title", args.title, "--body-file", args.body_file)
        if args.draft and not existing.get("isDraft"):
            gh("pr", "ready", "--undo", str(number))
        elif not args.draft and existing.get("isDraft"):
            gh("pr", "ready", str(number))
        print(f"PR #{number} updated ({'draft' if args.draft else 'ready'}) {existing['url']}")
        return EXIT_OK
    if not args.no_push:
        push_branch(name)
    create = [
        "pr", "create", "--base", default, "--head", name,
        "--title", args.title, "--body-file", args.body_file,
    ]
    if args.draft:
        create.append("--draft")
    url = gh(*create)
    number = pr_for(name)["number"] if pr_for(name) else "?"
    print(f"PR #{number} created ({'draft' if args.draft else 'ready'}) {url}")
    return EXIT_OK


def verdict(state: dict, require_review: bool) -> int:
    """Classify a PR state into an exit code; EXIT_REFUSED means wait longer."""
    pr = state["pr"]
    if pr is None:
        return EXIT_REFUSED
    if pr["state"] == "MERGED":
        return EXIT_GONE
    if pr["state"] == "CLOSED":
        return EXIT_GONE
    if pr.get("mergeable") == "CONFLICTING":
        return EXIT_CONFLICT
    if (pr.get("reviewDecision") or "") == "CHANGES_REQUESTED":
        return EXIT_CHANGES
    checks = state["checks"]
    if checks["state"] == "fail":
        return EXIT_CHECKS
    if checks["state"] == "pending":
        return EXIT_REFUSED
    approved = (pr.get("reviewDecision") or "") == "APPROVED"
    if require_review and not approved:
        return EXIT_REFUSED
    return EXIT_APPROVED


def describe(state: dict) -> str:
    pr = state["pr"]
    review = (pr.get("reviewDecision") or "no review").lower() if pr else "no pr"
    return f"#{pr['number'] if pr else '?'} {pr['state'].lower() if pr else '-'} · {review} · checks {state['checks']['state']}"


def cmd_watch(args: argparse.Namespace) -> int:
    interval = parse_duration(args.interval)
    deadline = time.monotonic() + parse_duration(args.timeout)
    last = None
    while True:
        state = collect()
        if state["pr"] is None:
            die(f"no PR for {state['branch']}; run 'open' first", EXIT_REFUSED)
        line = describe(state)
        if line != last:
            print(line, flush=True)
            last = line
        code = verdict(state, args.require_review)
        if code != EXIT_REFUSED or args.once:
            if code == EXIT_APPROVED:
                print(f"ready to merge #{state['pr']['number']}", flush=True)
            elif code == EXIT_CHANGES:
                print("changes requested; see 'gh pr view --comments'", flush=True)
            elif code == EXIT_CONFLICT:
                print(
                    f"conflicts with {state['pr']['baseRefName']}; rebase onto {state['base']}",
                    flush=True,
                )
            elif code == EXIT_CHECKS:
                print(f"checks failing: {', '.join(state['checks']['failing'])}", flush=True)
            elif code == EXIT_GONE:
                print(f"PR #{state['pr']['number']} is {state['pr']['state'].lower()}", flush=True)
            return code
        if time.monotonic() >= deadline:
            print(f"timeout after {args.timeout}", flush=True)
            return EXIT_TIMEOUT
        time.sleep(min(interval, max(0.0, deadline - time.monotonic())))


def primary_worktree() -> str:
    ok, out = git_ok("worktree", "list", "--porcelain")
    for line in out.splitlines():
        if line.startswith("worktree "):
            return line.split(" ", 1)[1]
    return "."


def cmd_merge(args: argparse.Namespace) -> int:
    state = collect()
    pr = state["pr"]
    if pr is None:
        die(f"no PR for {state['branch']}; run 'open' first", EXIT_REFUSED)
    code = verdict(state, args.require_review)
    if code == EXIT_CHANGES:
        die("changes requested; address them before merging", EXIT_CHANGES)
    if code == EXIT_CONFLICT:
        die(f"conflicts with {pr['baseRefName']}; rebase onto {state['base']}", EXIT_CONFLICT)
    if code == EXIT_CHECKS:
        die(f"checks failing: {', '.join(state['checks']['failing'])}", EXIT_CHECKS)
    if code == EXIT_APPROVED and pr.get("mergeable") != "MERGEABLE":
        # GitHub computes mergeability lazily; give it a moment before refusing.
        for _ in range(10):
            time.sleep(3)
            state = collect()
            pr = state["pr"]
            if pr.get("mergeable") == "MERGEABLE":
                break
        if pr.get("mergeable") != "MERGEABLE":
            die(f"mergeable is {pr.get('mergeable')}", EXIT_REFUSED)
    if code != EXIT_APPROVED:
        why = "checks pending" if state["checks"]["state"] == "pending" else "review not approved"
        die(why, EXIT_REFUSED)
    number = str(pr["number"])
    gh("pr", "merge", number, "--rebase", "--match-head-commit", pr["headRefOid"])
    merged = pr_for(state["branch"]) or {}
    sha = (merged.get("mergeCommit") or {}).get("oid", "")
    print(f"merged #{number} into {pr['baseRefName']}{f' as {sha}' if sha else ''}")
    default = state["default"]
    fetch_if_stale(default, max_age=0)
    behind = divergence(default, f"origin/{default}")[0]
    if behind:
        print(
            f"local {default} is {behind} behind origin/{default}; "
            f"git -C {primary_worktree()} pull --ff-only"
        )
    return EXIT_OK


def parse_duration(value: str) -> float:
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([smh]?)\s*", value)
    if not match:
        die(f"bad duration '{value}'; use e.g. 30s, 5m, 2h", EXIT_ENV)
    amount = float(match.group(1))
    return amount * {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2)]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="pr.py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status", help="report branch, base, commits, PR and checks")
    status.add_argument("--json", action="store_true", help="machine-readable output")
    status.add_argument("--branch", help="branch or PR ref to inspect instead of HEAD")
    status.set_defaults(func=cmd_status)

    open_ = sub.add_parser("open", help="create the PR for this branch, or update it")
    open_.add_argument("--draft", action="store_true", help="open as a draft")
    open_.add_argument("--title", required=True)
    open_.add_argument("--body-file", required=True)
    open_.add_argument("--no-push", action="store_true", help="assume the branch is already pushed")
    open_.set_defaults(func=cmd_open)

    watch = sub.add_parser("watch", help="poll until approved, rejected or failing")
    watch.add_argument("--interval", default="30s")
    watch.add_argument("--timeout", default="2h")
    watch.add_argument("--once", action="store_true", help="evaluate once and exit")
    watch.add_argument(
        "--require-review",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="wait for an approving review (default); --no-require-review waits for checks only",
    )
    watch.set_defaults(func=cmd_watch)

    merge = sub.add_parser("merge", help="re-check state and merge with --rebase")
    merge.add_argument(
        "--require-review",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="refuse without an approving review (default)",
    )
    merge.set_defaults(func=cmd_merge)

    args = parser.parse_args(argv)
    require_tools("git")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
