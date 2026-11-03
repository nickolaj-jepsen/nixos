"""What wt asks GitHub, through `gh` and the optional `gh stack` extension.

Every call here is optional to the verbs that clean up: when `gh` is missing, offline or
unauthenticated they get None and keep what they would otherwise have deleted.
"""

from __future__ import annotations

import json
import os
import subprocess
from functools import lru_cache
from typing import Optional

from .git import die, run
from .repo import Repo

_ENV = {"GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_SPINNER_DISABLED": "1"}
# A hung network call at session exit must not keep a folder alive for long.
_TIMEOUT = 30


class GhError(Exception):
    """`gh` failed or could not run; the message is what it said."""


def gh(cwd: str, *args: str) -> str:
    try:
        proc = subprocess.run(
            ["gh", *args], cwd=cwd, capture_output=True, text=True, env={**os.environ, **_ENV}, timeout=_TIMEOUT
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GhError(str(error)) from error
    if proc.returncode != 0:
        raise GhError((proc.stderr or proc.stdout).strip())
    return proc.stdout


def has_origin(repo: Repo) -> bool:
    return run(["git", "--git-dir", repo.common, "remote", "get-url", "origin"], check=False).returncode == 0


@lru_cache(maxsize=None)
def merged_heads(main: str) -> Optional[frozenset[tuple[str, str]]]:
    """(branch name, head sha) of the repo's recently merged PRs; None when GitHub can't be asked.

    A name alone proves nothing: branch names are reused, so a merge only counts at the same sha.
    """
    try:
        out = gh(main, "pr", "list", "--state", "merged", "--limit", "200", "--json", "headRefName,headRefOid")
        return frozenset((pr["headRefName"], pr["headRefOid"]) for pr in json.loads(out or "[]"))
    except (GhError, ValueError, KeyError, TypeError):
        return None


def pr_merged(repo: Repo, branch: str, sha: str) -> bool:
    if not has_origin(repo):
        return False
    heads = merged_heads(repo.main)
    return bool(heads) and (branch, sha) in heads


def stack(path: str) -> Optional[dict]:
    """`gh stack view --json` for the stack checked out in `path`; None when it holds none."""
    try:
        return json.loads(gh(path, "stack", "view", "--json"))
    except (GhError, ValueError):
        return None


def stack_layers(path: str) -> list[str]:
    found = stack(path)
    return [branch["name"] for branch in (found or {}).get("branches", []) if branch.get("name")]


def pr_view(path: str, ref: str) -> Optional[dict]:
    """The PR for `ref`; None when there is none. Other failures stop wt."""
    fields = "number,state,isDraft,url,headRefOid,mergeable,statusCheckRollup,baseRefName"
    try:
        return json.loads(gh(path, "pr", "view", ref, "--json", fields))
    except GhError as error:
        if "no pull requests found" in str(error).lower():
            return None
        die(f"gh pr view {ref} failed: {error}")


def checks_state(pr: dict) -> tuple[str, list[str]]:
    """`pass`, `fail`, `pending` or `none` for a PR's status checks, with the failing names."""
    passed = failing = pending = 0
    names: list[str] = []
    for entry in pr.get("statusCheckRollup") or []:
        name = entry.get("name") or entry.get("context") or "check"
        if entry.get("__typename") == "StatusContext":
            state = (entry.get("state") or "").upper()
            outcome = "pass" if state == "SUCCESS" else "pending" if state in ("PENDING", "EXPECTED", "") else "fail"
        else:
            status = (entry.get("status") or "").upper()
            conclusion = (entry.get("conclusion") or "").upper()
            if status and status != "COMPLETED":
                outcome = "pending"
            elif conclusion in ("SUCCESS", "NEUTRAL", "SKIPPED"):
                outcome = "pass"
            elif conclusion:
                outcome = "fail"
            else:
                outcome = "pending"
        if outcome == "fail":
            failing += 1
            names.append(name)
        elif outcome == "pending":
            pending += 1
        else:
            passed += 1
    if failing:
        return "fail", names
    if pending:
        return "pending", []
    return ("pass" if passed else "none"), []


def requires_checks(path: str, branch: str) -> bool:
    """Whether merges into `branch` must pass status checks, by repository rules or branch protection."""
    try:
        rules = json.loads(gh(path, "api", f"repos/{{owner}}/{{repo}}/rules/branches/{branch}") or "[]")
        if any(rule.get("type") == "required_status_checks" for rule in rules):
            return True
    except (GhError, ValueError, AttributeError):
        pass
    try:
        protection = json.loads(gh(path, "api", f"repos/{{owner}}/{{repo}}/branches/{branch}/protection/required_status_checks"))
        return bool(protection.get("contexts") or protection.get("checks"))
    except (GhError, ValueError, AttributeError):
        return False
