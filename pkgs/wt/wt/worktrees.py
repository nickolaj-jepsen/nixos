"""The worktrees wt knows about, open or closed, and the git facts about each.

A worktree is open while its folder exists. Closing removes the folder and keeps the branch,
recorded in git config `wt.<name>.head`, so `wt new <name>` can bring it back.
"""

from __future__ import annotations

import contextlib
import os
import time
from dataclasses import dataclass, field
from typing import Callable, Iterator, Optional, TypeVar

from .git import ProbeError, die, git_ok, is_within, probe, run
from .procs import busy_pids
from .repo import Repo, registered_worktrees

T = TypeVar("T")

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
    # The commit a registration recorded, which is all a closed detached worktree still knows.
    head: Optional[str] = None

    @property
    def open(self) -> bool:
        return self.path is not None


@dataclass
class Row:
    """One worktree as listing reports it: a status value that could not be inspected stays None.

    `errors` carries the reason, so a partial row says which of its values are unknown instead of
    presenting a failed probe as a clean tree or a zero count.
    """

    name: str
    branch: str
    path: Optional[str]
    open: bool
    ahead: Optional[int] = None
    landed: Optional[bool] = None
    dirty: Optional[bool] = None
    wip: Optional[bool] = None
    busy: bool = False
    idle_seconds: Optional[int] = None
    errors: list[str] = field(default_factory=list)

    @property
    def error(self) -> Optional[str]:
        """Why some values are unknown, or None when every probe answered."""
        return "; ".join(self.errors) or None


def dir_name(branch: str) -> str:
    return branch.replace("/", "-")


@contextlib.contextmanager
def read_only_git() -> Iterator[None]:
    """Make every git call forgo optional locks, so an inspection cannot change what it reads.

    With optional locks, `git status` refreshes the stat information in the index it reads, which
    both mutates the checkout and resets the idle time reported from that index to 0s.
    """
    previous = os.environ.get("GIT_OPTIONAL_LOCKS")
    os.environ["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop("GIT_OPTIONAL_LOCKS", None)
        else:
            os.environ["GIT_OPTIONAL_LOCKS"] = previous


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


def layers(repo: Repo, name: str) -> list[str]:
    """The stack layers `name` held when it was closed, besides its head branch."""
    out = run(["git", "--git-dir", repo.common, "config", "--get-all", f"wt.{name}.layer"], check=False).stdout
    return [line for line in out.splitlines() if line]


def set_layers(repo: Repo, name: str, branches: list[str]) -> None:
    run(["git", "--git-dir", repo.common, "config", "--unset-all", f"wt.{name}.layer"], check=False)
    for branch in branches:
        run(["git", "--git-dir", repo.common, "config", "--add", f"wt.{name}.layer", branch])


def clear_record(repo: Repo, name: str) -> None:
    run(["git", "--git-dir", repo.common, "config", "--remove-section", f"wt.{name}"], check=False)


def branch_exists(repo: Repo, branch: str) -> bool:
    return bool(branch) and git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}")


def entries(repo: Repo) -> list[Entry]:
    """Every worktree except the primary checkout: open ones first, then closed ones whose branch still exists.

    A registration whose folder is gone lists as closed: git keeps it until `worktree prune`, and a
    dead path is not an open worktree.
    """
    found: list[Entry] = []
    for item in registered_worktrees(repo.common)[1:]:
        path = item["path"] if os.path.isdir(item["path"]) else None
        found.append(
            Entry(os.path.basename(item["path"]), item["branch"], path, item["locked"], item["head"] or None)
        )
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
    """The in-progress operation's label, or None; a marker file that is absent is the normal answer.

    Raises ProbeError when git cannot name its own state directories, so the absence stays unproven.
    """
    for marker, label in _OPERATIONS.items():
        found = probe(path, "rev-parse", "--path-format=absolute", "--git-path", marker).strip()
        if found and os.path.exists(found):
            return label
    return None


def conflicted(path: str) -> list[str]:
    """Paths with unresolved conflicts; raises ProbeError when git cannot answer."""
    return [line for line in probe(path, "diff", "--name-only", "--diff-filter=U").splitlines() if line]


def dirty(path: str) -> bool:
    """Whether the working tree holds uncommitted work, ignored paths aside.

    `--untracked-files=all` overrides status.showUntrackedFiles, which would otherwise hide exactly
    the untracked-only work a close has to commit. Raises ProbeError when git cannot answer.
    """
    return bool(probe(path, "status", "--porcelain", "--untracked-files=all").strip())


def branches_containing(path: str, ref: str) -> list[str]:
    """Branches whose history has `ref`; raises ProbeError when git cannot answer."""
    return [line for line in probe(path, "branch", "--contains", ref, "--format=%(refname)").splitlines() if line]


def is_wip(cwd: str, ref: str) -> bool:
    """Whether `ref` is a wip commit from `close`; raises ProbeError when git cannot answer."""
    value = probe(cwd, "log", "-1", f"--format=%(trailers:key={WIP_KEY},valueonly)", ref, "--")
    return value.strip() == "1"


def head_of(repo: Repo, entry: Entry) -> tuple[str, str]:
    """The checkout and ref holding an entry's own commits.

    A detached worktree has its own HEAD, and a closed registration keeps the commit git recorded
    for it, so the primary checkout is never the right place to ask about either. Raises ProbeError
    when nothing identifies the entry's commits, rather than answering with another checkout's.
    """
    if entry.branch:
        return repo.main, entry.branch
    if entry.path:
        return entry.path, "HEAD"
    if entry.head:
        return repo.main, entry.head
    raise ProbeError(f"'{entry.name}' is closed with no branch and no recorded commit to read")


def ahead(repo: Repo, ref: str, cwd: Optional[str] = None) -> int:
    """Commits `ref` in `cwd` has that the default branch does not; raises ProbeError rather than counting 0."""
    out = probe(cwd or repo.main, "rev-list", "--count", f"{repo.default}..{ref}", "--").strip()
    if not out.isdigit():
        raise ProbeError(f"git rev-list --count {repo.default}..{ref} answered {out!r}, not a count")
    return int(out)


def landed(repo: Repo, ref: str, cwd: Optional[str] = None) -> Optional[bool]:
    """Whether every commit of `ref` in `cwd` is in the default branch; None when git cannot tell.

    `merge-base --is-ancestor` exits 1 for a normal no, so only any other failure is unknown.
    """
    proc = run(["git", "-C", cwd or repo.main, "merge-base", "--is-ancestor", ref, repo.default], check=False)
    if proc.returncode == 0:
        return True
    return False if proc.returncode == 1 else None


def idle_seconds(repo: Repo, entry: Entry) -> int:
    """Seconds since the latest git-metadata activity on the entry: its commit, HEAD and index.

    Working-tree file mtimes are ignored on purpose: they move on every save and say nothing about
    whether the work is idle. A detached worktree's commit is its own, not the primary tip's.
    Raises ProbeError when git cannot name the entry's commit or metadata directory.
    """
    now = int(time.time())
    cwd, ref = head_of(repo, entry)
    stamps: list[int] = []
    commit = probe(cwd, "log", "-1", "--format=%ct", ref, "--").strip()
    if not commit.isdigit():
        raise ProbeError(f"git log -1 --format=%ct {ref} in {cwd} answered {commit!r}, not a commit time")
    stamps.append(int(commit))
    if entry.path:
        git_dir = probe(entry.path, "rev-parse", "--path-format=absolute", "--git-dir").strip()
        for name in ("HEAD", "index"):
            try:
                stamps.append(int(os.stat(os.path.join(git_dir, name)).st_mtime))
            except OSError:
                pass
    return max(0, now - max(stamps))


def inspect_row(repo: Repo, entry: Entry) -> Row:
    """Every listing fact about `entry`, keeping the ones that answered.

    One damaged checkout must not cost the whole listing its other rows, so a probe that raises
    leaves its value unknown and records the reason on the row instead of ending the verb.
    """
    row = Row(name=entry.name, branch=entry.branch, path=entry.path, open=entry.open)

    def asked(question: Callable[[], T]) -> Optional[T]:
        try:
            return question()
        except ProbeError as error:
            row.errors.append(str(error))
            return None

    def ahead_of() -> int:
        cwd, ref = head_of(repo, entry)
        return ahead(repo, ref, cwd)

    def landed_of() -> bool:
        cwd, ref = head_of(repo, entry)
        answer = landed(repo, ref, cwd)
        if answer is None:
            raise ProbeError(f"could not tell whether {ref} is in {repo.default}")
        return answer

    row.ahead = asked(ahead_of)
    row.landed = asked(landed_of)
    # A closed worktree has no folder, so there is nothing of it to be dirty or busy.
    row.dirty = asked(lambda: dirty(entry.path or "")) if entry.path else False
    row.busy = bool(entry.path) and bool(busy_pids(entry.path or ""))
    row.wip = asked(lambda: is_wip(repo.main, entry.branch)) if entry.branch else False
    row.idle_seconds = asked(lambda: idle_seconds(repo, entry))
    return row
