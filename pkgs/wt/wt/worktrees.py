"""The worktrees wt knows about, open or closed, and the git facts about each.

A worktree is open while its folder exists. Closing removes the folder and keeps the branch,
recorded in git config `wt.<name>.head`, so `wt new <name>` can bring it back.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import Optional

from .git import die, git, git_ok, is_within, run
from .repo import Repo, registered_worktrees

# The trailer that marks the commit `close` makes from uncommitted changes.
WIP_KEY = "Wt-Wip"
WIP_TRAILER = f"{WIP_KEY}: 1"
# In-progress operations that leave a working tree half-way; closing one would bury the state.
_OPERATIONS = {
    "rebase-merge": "rebase",
    "rebase-apply": "rebase",
    "MERGE_HEAD": "merge",
    "CHERRY_PICK_HEAD": "cherry-pick",
    "REVERT_HEAD": "revert",
    "BISECT_LOG": "bisect",
}


@dataclass
class Entry:
    name: str
    branch: str
    path: Optional[str]
    locked: bool = False

    @property
    def open(self) -> bool:
        return self.path is not None


def dir_name(branch: str) -> str:
    return branch.replace("/", "-")


def records(repo: Repo) -> dict[str, str]:
    """Closed-or-open worktree name to the branch it last had checked out."""
    out = run(
        ["git", "--git-dir", repo.common, "config", "--get-regexp", r"^wt\..*\.head$"], check=False
    ).stdout
    found: dict[str, str] = {}
    for line in out.splitlines():
        key, _, value = line.partition(" ")
        found[key[len("wt.") : -len(".head")]] = value
    return found


def set_record(repo: Repo, name: str, branch: str) -> None:
    run(["git", "--git-dir", repo.common, "config", f"wt.{name}.head", branch])


def clear_record(repo: Repo, name: str) -> None:
    run(["git", "--git-dir", repo.common, "config", "--remove-section", f"wt.{name}"], check=False)


def branch_exists(repo: Repo, branch: str) -> bool:
    return bool(branch) and git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}")


def entries(repo: Repo) -> list[Entry]:
    """Every worktree except the primary checkout: open ones first, then closed ones whose branch still exists."""
    found: list[Entry] = []
    for item in registered_worktrees(repo.common)[1:]:
        found.append(Entry(os.path.basename(item["path"]), item["branch"], item["path"], item["locked"]))
    open_names = {entry.name for entry in found}
    for name, branch in sorted(records(repo).items()):
        if name not in open_names and branch_exists(repo, branch):
            found.append(Entry(name, branch, None))
    return found


def resolve(repo: Repo, target: str) -> Entry:
    """The worktree a name, a path, or `.` (the one holding the cwd) names."""
    known = entries(repo)
    if target == "." or os.path.isabs(target):
        inside = os.path.realpath(os.getcwd() if target == "." else target)
        if is_within(inside, os.path.realpath(repo.main)) and not any(
            entry.path and is_within(inside, os.path.realpath(entry.path)) for entry in known
        ):
            die(f"{repo.main} is the primary checkout, not a worktree")
        for entry in sorted((e for e in known if e.path), key=lambda e: len(e.path or ""), reverse=True):
            if is_within(inside, os.path.realpath(entry.path or "")):
                return entry
        die(f"{'the current directory' if target == '.' else target} is not inside a worktree")
    for match in (
        lambda e: e.name == target,
        lambda e: e.name == dir_name(target),
        lambda e: e.branch == target,
    ):
        hits = [entry for entry in known if match(entry)]
        if len(hits) == 1:
            return hits[0]
        if len(hits) > 1:
            die(f"'{target}' is ambiguous: {', '.join(entry.path or entry.name for entry in hits)}")
    die(f"no worktree named '{target}'")


def operation_in_progress(path: str) -> Optional[str]:
    for marker, label in _OPERATIONS.items():
        proc = run(["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-path", marker], check=False)
        if proc.returncode == 0 and os.path.exists(proc.stdout.strip()):
            return label
    return None


def conflicted(path: str) -> list[str]:
    return [line for line in git(path, "diff", "--name-only", "--diff-filter=U", check=False).splitlines() if line]


def dirty(path: str) -> bool:
    return bool(git(path, "status", "--porcelain", check=False).strip())


def is_wip(cwd: str, ref: str) -> bool:
    value = git(cwd, "log", "-1", f"--format=%(trailers:key={WIP_KEY},valueonly)", ref, "--", check=False)
    return value.strip() == "1"


def ahead(repo: Repo, ref: str) -> int:
    out = git(repo.main, "rev-list", "--count", f"{repo.default}..{ref}", "--", check=False).strip()
    return int(out) if out.isdigit() else 0


def landed(repo: Repo, ref: str) -> bool:
    """Whether every commit of `ref` is already in the default branch."""
    return git_ok(repo.main, "merge-base", "--is-ancestor", ref, repo.default)


def idle_seconds(repo: Repo, entry: Entry) -> int:
    now = int(time.time())
    stamps: list[int] = []
    commit = git(repo.main, "log", "-1", "--format=%ct", entry.branch or "HEAD", "--", check=False).strip()
    if commit.isdigit():
        stamps.append(int(commit))
    if entry.path:
        git_dir = git(entry.path, "rev-parse", "--path-format=absolute", "--git-dir", check=False).strip()
        for name in ("HEAD", "index"):
            try:
                stamps.append(int(os.stat(os.path.join(git_dir, name)).st_mtime))
            except OSError:
                pass
    return max(0, now - max(stamps)) if stamps else 0
