"""Where agent notes live, and which repository a note belongs to.

The durable store is per checkout, not per repository host: two clones of one
project are two workbench drawers. Every worktree of a checkout shares one id,
and a working directory outside git falls back to `global`.

A checkout sees its store through two links, `<root>/.agents/store` and
`<root>/.agents/tmp`, so an editor shows the notes beside the code while git
only ever sees a link it may delete.
"""

import hashlib
import os
import re
import subprocess
from pathlib import Path

GLOBAL = "global"
ORPHANED = "_orphaned"
RESERVED = {GLOBAL, ORPHANED}
# A repo id is a basename plus a hash, so only these characters can appear.
UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")
TIMEOUT = 10


def data_root():
    """The agents' data directory: the store and anything outside it, such as `_orphaned`."""
    configured = os.environ.get("AGENT_NOTES_DATA")
    if configured:
        return Path(configured)
    base = os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share"
    return Path(base) / "agents"


def store_root():
    return data_root() / "store"


def orphan_root():
    return data_root() / ORPHANED


def state_root():
    """Scratch, which is disposable: `tmp/<repo>/<pid>`."""
    configured = os.environ.get("AGENT_NOTES_STATE")
    if configured:
        return Path(configured)
    base = os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state"
    return Path(base) / "agents"


def tmp_root():
    return state_root() / "tmp"


def _git(*args, cwd):
    try:
        out = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def worktree_root(path):
    """The working tree `path` is in, or None outside git."""
    if not path or not os.path.isdir(path):
        return None
    top = _git("rev-parse", "--show-toplevel", cwd=path)
    return os.path.realpath(top) if top else None


def main_worktree(path):
    """The main checkout's root, which every worktree of it names in its id.

    `git worktree list --porcelain` lists the main worktree first and promises the
    format stays stable. A bare repository has no worktree, so its own directory
    stands in.
    """
    listed = _git("worktree", "list", "--porcelain", cwd=path)
    if listed:
        for line in listed.splitlines():
            if line.startswith("worktree "):
                return os.path.realpath(line[len("worktree "):])
    if _git("rev-parse", "--is-bare-repository", cwd=path) == "true":
        common = _git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=path)
        return os.path.realpath(common) if common else None
    return worktree_root(path)


def repo_id(path):
    """The store directory name for `path`: `<main checkout's basename>-<path hash>`.

    The hash is of the real main worktree path, so it survives `git worktree add`,
    and two checkouts that share a basename never share notes.
    """
    main = main_worktree(path)
    if main is None:
        return GLOBAL
    name = UNSAFE.sub("-", os.path.basename(main)).strip("-.") or "repo"
    digest = hashlib.sha256(main.encode()).hexdigest()[:8]
    return f"{name}-{digest}"


def project_dir(path):
    """The durable store directory for the checkout `path` is in (not created)."""
    return store_root() / repo_id(path)


def scratch_dir(path, pid=None):
    """The scratch directory for a session in `path` (not created)."""
    return tmp_root() / repo_id(path) / str(pid if pid is not None else os.getpid())


def links(root):
    """The two link paths a checkout root exposes: name → store and scratch targets."""
    return {
        "store": (Path(root) / ".agents" / "store", store_root() / repo_id(root)),
        "tmp": (Path(root) / ".agents" / "tmp", tmp_root() / repo_id(root)),
    }
