"""Creating the two links a checkout exposes, and refusing to clobber anything."""

import os
from pathlib import Path

from .layout import links, repo_id, worktree_root


def _tracked(root, relative):
    """Whether git already tracks the link path; a tracked symlink would bake a home path into clones."""
    try:
        import subprocess

        out = subprocess.run(["git", "ls-files", "--error-unmatch", "--", relative], cwd=root,
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return out.returncode == 0


def ensure(root, create_store=False, report=None):
    """Make `<root>/.agents/{store,tmp}` point at this checkout's store and scratch.

    Never replaces a real file, a real directory, a tracked path, or a symlink
    pointing somewhere else. Returns the problems it refused to fix, so `init`
    can print them without failing the git hook that ran it.
    """
    say = report or (lambda _message: None)
    root = os.path.realpath(root)
    if worktree_root(root) is None or repo_id(root) == "global":
        return []
    if not os.path.isdir(Path(root) / ".git") and not _is_linked_worktree(root):
        return []
    directory = Path(root) / ".agents"
    problems = []
    for name, (path, target) in links(root).items():
        relative = f".agents/{name}"
        # Scratch is cheap and always has a target; the store appears with the first note.
        if name == "tmp" or create_store:
            target.mkdir(parents=True, exist_ok=True)
        if _tracked(root, relative):
            problems.append(f"{relative} is tracked by git; commit a real directory or remove it, not a link")
            continue
        if path.is_symlink():
            if os.readlink(path) == str(target):
                continue
            problems.append(f"{relative} is a link to {os.readlink(path)}, not to {target}; leaving it alone")
            continue
        if path.exists():
            problems.append(f"{relative} is a real file or directory; leaving it alone")
            continue
        directory.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
        say(f"linked {relative} -> {target}")
    return problems


def _is_linked_worktree(root):
    """A worktree's `.git` is a file pointing at the main checkout's git directory."""
    git_file = Path(root) / ".git"
    try:
        return git_file.is_file() and git_file.read_text().startswith("gitdir:")
    except OSError:
        return False
