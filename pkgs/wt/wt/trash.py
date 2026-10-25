"""Archived worktrees: archive, list, purge and restore."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import tarfile
import time
from pathlib import Path

from .git import die, git, git_ok, info, run
from .repo import Repo, RepoLock, current_repo, repos_under_root
from .status import Worktree
from .ui import _table, format_age

TRASH_VERSION = 1


def _trash_id(name: str) -> str:
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or "worktree"
    return f"{stamp}-{safe}"


def _trash_meta(directory: str) -> dict:
    try:
        return json.loads(Path(os.path.join(directory, "meta.json")).read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def _archive_untracked(path: str, target: str) -> list[str]:
    proc = run(["git", "-C", path, "ls-files", "-z", "--others", "--exclude-standard"], check=False)
    files = [name for name in proc.stdout.split("\0") if name]
    if not files:
        return []
    with tarfile.open(target, "w:gz") as archive:
        for name in files:
            full = os.path.join(path, name)
            if os.path.lexists(full):
                archive.add(full, arcname=name, recursive=False)
    return files


def archive_worktree(repo: Repo, row: Worktree) -> str:
    os.makedirs(repo.trash_dir, exist_ok=True)
    trash_id = _trash_id(row.name)
    directory = os.path.join(repo.trash_dir, trash_id)
    os.makedirs(directory)
    stash = run(["git", "-C", row.path, "stash", "create"], check=False).stdout.strip()
    if row.state == "dirty" and not stash:
        die(f"could not archive the tracked changes in '{row.name}'; nothing was removed")
    head = git(row.path, "rev-parse", "HEAD", check=False).strip()
    point = stash or head
    ref = f"refs/wt/trash/{trash_id}"
    if point:
        run(["git", "--git-dir", repo.common, "update-ref", ref, point], check=False)
    untracked = _archive_untracked(row.path, os.path.join(directory, "untracked.tar.gz"))
    meta = {
        "version": TRASH_VERSION,
        "id": trash_id,
        "kind": "worktree",
        "repo": repo.common,
        "repoKey": repo.key,
        "name": row.name,
        "branch": row.branch,
        "path": row.path,
        "head": head,
        "stash": stash or None,
        "ref": ref,
        "untracked": untracked,
        "defaultBranch": repo.default,
        "created": int(time.time()),
    }
    Path(os.path.join(directory, "meta.json")).write_text(json.dumps(meta, indent=2) + "\n")
    return trash_id


def archive_orphan(repo: Repo, row: Worktree) -> str:
    os.makedirs(repo.trash_dir, exist_ok=True)
    trash_id = _trash_id(row.name)
    directory = os.path.join(repo.trash_dir, trash_id)
    os.makedirs(directory)
    run(["mv", "--", row.path, os.path.join(directory, "tree")])
    meta = {
        "version": TRASH_VERSION,
        "id": trash_id,
        "kind": "orphan",
        "repo": repo.common,
        "repoKey": repo.key,
        "name": row.name,
        "branch": "",
        "path": row.path,
        "created": int(time.time()),
    }
    Path(os.path.join(directory, "meta.json")).write_text(json.dumps(meta, indent=2) + "\n")
    return trash_id


def _trash_entries(repo: Repo) -> list[dict]:
    if not os.path.isdir(repo.trash_dir):
        return []
    entries = []
    for entry in sorted(os.scandir(repo.trash_dir), key=lambda e: e.name):
        if not entry.is_dir(follow_symlinks=False):
            continue
        meta = _trash_meta(entry.path)
        if not meta:
            continue
        meta["_dir"] = entry.path
        entries.append(meta)
    return entries


def cmd_trash(args: argparse.Namespace) -> None:
    repo = current_repo() if not args.all else None
    repos = repos_under_root() if args.all else [repo]
    entries: list[dict] = []
    for item in repos:
        for meta in _trash_entries(item):
            meta["_repo"] = item
            entries.append(meta)
    if args.action == "list":
        if args.json:
            print(json.dumps({"version": TRASH_VERSION, "entries": entries_without_private(entries)}, indent=2))
            return
        if not entries:
            info("trash is empty")
            return
        body = []
        for meta in entries:
            size = directory_size(meta["_dir"])
            body.append([
                meta.get("id", "?"),
                meta.get("name", "?"),
                meta.get("kind", "?"),
                meta.get("branch") or "-",
                format_age(max(0, int(time.time()) - int(meta.get("created", 0)))),
                human_size(size),
            ])
        print(_table(body, ["ID", "NAME", "KIND", "BRANCH", "AGE", "SIZE"]))
        return

    # purge
    matches = entries if args.all else [meta for meta in entries if meta.get("id") == args.id]
    if not matches:
        die("no trash entry named" + (f" '{args.id}'" if args.id else ""))
    for meta in matches:
        if meta.get("ref"):
            run(["git", "--git-dir", meta["_repo"].common, "update-ref", "-d", meta["ref"]], check=False)
        shutil.rmtree(meta["_dir"], ignore_errors=True)
        info(f"purged {meta.get('id')}")


def entries_without_private(entries: list[dict]) -> list[dict]:
    return [{key: value for key, value in meta.items() if not key.startswith("_")} for meta in entries]


def directory_size(path: str) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.stat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "K", "M", "G", "T"):
        if value < 1024 or unit == "T":
            return f"{value:.0f}{unit}" if unit == "B" else f"{value:.1f}{unit}"
        value /= 1024
    return f"{size}B"


def cmd_restore(args: argparse.Namespace) -> None:
    repo = current_repo()
    with RepoLock(repo):
        entries = _trash_entries(repo)
        meta = next((item for item in entries if item.get("id") == args.id), None)
        if meta is None:
            die(f"no trash entry named '{args.id}'")
        name = args.name or meta.get("name") or "restored"
        branch = args.name or meta.get("branch") or name
        directory_name = name.replace("/", "-")
        path = os.path.join(repo.directory, directory_name)
        if os.path.exists(path):
            die(f"'{path}' already exists; pass --name <new-name> to restore elsewhere")
        if git_ok(repo.main, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"):
            die(f"branch '{branch}' already exists; pass --name <new-name> to restore elsewhere")

        if meta.get("kind") == "orphan":
            source = os.path.join(meta["_dir"], "tree")
            if not os.path.isdir(source):
                die(f"trash entry '{args.id}' has no directory to restore")
            run(["mv", "--", source, path])
        else:
            head = meta.get("head")
            if not head:
                die(f"trash entry '{args.id}' has no recorded commit")
            run(["git", "-C", repo.main, "worktree", "add", "-b", branch, path, head])
            stash = meta.get("stash")
            if stash:
                proc = run(["git", "-C", path, "stash", "apply", stash], check=False)
                if proc.returncode != 0:
                    die(
                        f"restored {path} but could not reapply its tracked changes; "
                        f"the archive is kept. Resolve manually in {path}"
                    )
            if meta.get("untracked"):
                archive = os.path.join(meta["_dir"], "untracked.tar.gz")
                if os.path.isfile(archive):
                    with tarfile.open(archive, "r:gz") as tar:
                        tar.extractall(path, filter="fully_trusted")
        if meta.get("ref"):
            run(["git", "--git-dir", repo.common, "update-ref", "-d", meta["ref"]], check=False)
        shutil.rmtree(meta["_dir"], ignore_errors=True)
        info(f"restored {name} at {path} on {branch}")
        print(path)
