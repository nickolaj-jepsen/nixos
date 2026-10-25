"""Repository identity, working-tree layout, discovery and the repo-wide lock."""

from __future__ import annotations

import fcntl
import hashlib
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .git import die, normpath, run

LOCK_WAIT_SECONDS = float(os.environ.get("WT_LOCK_WAIT_SECONDS") or 10.0)


def worktree_root() -> str:
    return normpath(os.environ.get("WT_WORKTREE_ROOT") or os.path.expanduser("~/worktrees"))


def trash_root() -> str:
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(base, "wt", "trash")


@dataclass
class Repo:
    common: str
    main: str
    key: str
    default: str
    directory: str

    @property
    def marker(self) -> str:
        return os.path.join(self.directory, ".wt-repo")

    @property
    def trash_dir(self) -> str:
        # The worktree directory name carries the collision suffix, so two
        # same-named repositories never share a trash.
        return os.path.join(trash_root(), os.path.basename(self.directory))

    @property
    def lock_path(self) -> str:
        return os.path.join(self.common, "wt.lock")


def discover_common(cwd: str) -> Optional[str]:
    proc = run(
        ["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
        check=False,
    )
    if proc.returncode != 0:
        return None
    common = proc.stdout.strip()
    return normpath(common) if common else None


def default_branch(common: str) -> str:
    proc = run(
        ["git", "--git-dir", common, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
        check=False,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        ref = proc.stdout.strip()
        return ref[len("refs/remotes/origin/") :] if ref.startswith("refs/remotes/origin/") else ref
    for branch in ("main", "master"):
        if run(
            ["git", "--git-dir", common, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"],
            check=False,
        ).returncode == 0:
            return branch
    die("could not determine default branch (no origin/HEAD, no main, no master)")


def registered_worktrees(common: str) -> list[dict]:
    out = run(["git", "--git-dir", common, "worktree", "list", "--porcelain"]).stdout
    items: list[dict] = []
    current: Optional[dict] = None
    for line in out.splitlines():
        if line.startswith("worktree "):
            current = {"path": normpath(line[len("worktree ") :]), "branch": "", "locked": False}
            items.append(current)
        elif current is None:
            continue
        elif line.startswith("branch "):
            ref = line[len("branch ") :]
            current["branch"] = ref[len("refs/heads/") :] if ref.startswith("refs/heads/") else ref
        elif line == "detached":
            current["branch"] = ""
        elif line.startswith("locked"):
            current["locked"] = True
    return items


def repo_from_common(common: str) -> Repo:
    registered = registered_worktrees(common)
    if not registered:
        die(f"no worktrees registered for {common}")
    main = registered[0]["path"]
    key = os.path.basename(os.path.dirname(common))
    return Repo(common=common, main=main, key=key, default=default_branch(common), directory=worktree_directory(common, key))


def current_repo(cwd: Optional[str] = None) -> Repo:
    common = discover_common(cwd or os.getcwd())
    if not common:
        die("not inside a git repository")
    return repo_from_common(common)


def _owner_of_dir(directory: str) -> Optional[str]:
    """The repo common dir claiming `directory`, or None when it holds no git worktree."""
    found: Optional[str] = None
    try:
        entries = sorted(os.scandir(directory), key=lambda e: e.name)
    except OSError:
        return None
    for entry in entries:
        if not entry.is_dir(follow_symlinks=False):
            continue
        dotgit = os.path.join(entry.path, ".git")
        if not os.path.exists(dotgit):
            continue
        common = discover_common(entry.path)
        if common is None:
            continue
        if found is None:
            found = common
        elif found != common:
            # Two repositories in one directory is not ours to resolve.
            return common
    return found


def worktree_directory(common: str, key: str) -> str:
    root = worktree_root()
    base = os.path.join(root, key)
    if os.path.exists(base):
        marker = os.path.join(base, ".wt-repo")
        recorded = None
        if os.path.exists(marker):
            try:
                recorded = normpath(Path(marker).read_text().strip())
            except OSError:
                recorded = None
        if recorded == common:
            return base
        owner = recorded or _owner_of_dir(base)
        if owner is None:
            # Legacy plain directories belong to this repo; record the claim.
            try:
                Path(marker).write_text(common + "\n")
            except OSError:
                pass
            return base
        if owner != common:
            suffix = hashlib.sha256(common.encode()).hexdigest()[:8]
            base = os.path.join(root, f"{key}-{suffix}")
    try:
        os.makedirs(base, exist_ok=True)
        marker = os.path.join(base, ".wt-repo")
        if not os.path.exists(marker):
            Path(marker).write_text(common + "\n")
    except OSError:
        pass
    return base


def repos_under_root() -> list[Repo]:
    root = worktree_root()
    repos: list[Repo] = []
    if not os.path.isdir(root):
        return repos
    for entry in sorted(os.scandir(root), key=lambda e: e.name):
        if not entry.is_dir(follow_symlinks=False):
            continue
        marker = os.path.join(entry.path, ".wt-repo")
        if not os.path.exists(marker):
            continue
        try:
            common = normpath(Path(marker).read_text().strip())
        except OSError:
            continue
        if not os.path.isdir(common):
            continue
        try:
            repos.append(repo_from_common(common))
        except SystemExit:
            continue
    return repos



# ---------------------------------------------------------------------------
# Locking


class RepoLock:
    def __init__(self, repo: Repo):
        self.repo = repo
        self.handle = None

    def __enter__(self):
        path = self.repo.lock_path
        try:
            self.handle = open(path, "a+")
        except OSError as error:
            die(f"could not open lock {path}: {error}")
        deadline = time.monotonic() + LOCK_WAIT_SECONDS
        while True:
            try:
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    self.handle.seek(0)
                    holder = (self.handle.read() or "").strip()
                    self.handle.close()
                    die(
                        "another wt is mutating this repository"
                        + (f" (pid {holder})" if holder else "")
                    )
                time.sleep(0.1)
        self.handle.seek(0)
        self.handle.truncate()
        self.handle.write(str(os.getpid()))
        self.handle.flush()
        return self

    def __exit__(self, *exc):
        if self.handle:
            try:
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
            finally:
                self.handle.close()
