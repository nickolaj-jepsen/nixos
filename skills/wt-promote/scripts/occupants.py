#!/usr/bin/env python3
"""Find the agent sessions working in a checkout, and wait for one to hand it over.

  occupants.py list <path>                 JSON array of live sessions whose cwd is inside <path>
  occupants.py wait <checkout> [--timeout S]
      one line per change, exit 0 once <checkout> is on its default branch and clean, 1 on timeout

Sessions come from the registry Claude Code and pi's claude-peers share (~/.claude/sessions,
or $CLAUDE_CONFIG_DIR/sessions). The session running this script, and its ancestors, never count.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def _ancestors() -> set[int]:
    pids = {os.getpid()}
    pid = os.getppid()
    while pid > 1 and pid not in pids:
        pids.add(pid)
        try:
            stat = Path(f"/proc/{pid}/stat").read_text()
        except OSError:
            break
        # The command name may contain spaces and parentheses; fields resume after the last ')'.
        pid = int(stat.rsplit(")", 1)[1].split()[1])
    return pids


def _start_time(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return ""


def _registries() -> list[Path]:
    dirs = [Path.home() / ".claude" / "sessions"]
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        dirs.insert(0, Path(os.environ["CLAUDE_CONFIG_DIR"]) / "sessions")
    seen: list[Path] = []
    for directory in dirs:
        real = directory.resolve()
        if real.is_dir() and real not in seen:
            seen.append(real)
    return seen


def _within(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def sessions_in(path: str) -> list[dict]:
    root = os.path.realpath(path)
    ours = _ancestors()
    found: dict[int, dict] = {}
    for registry in _registries():
        for file in registry.glob("*.json"):
            try:
                entry = json.loads(file.read_text())
                pid = int(entry["pid"])
            except (OSError, ValueError, KeyError, TypeError):
                continue
            if pid in ours or pid in found or not os.path.exists(f"/proc/{pid}"):
                continue
            # A recycled pid belongs to some other process now.
            if entry.get("procStart") and entry["procStart"] != _start_time(pid):
                continue
            cwd = os.path.realpath(entry.get("cwd") or "")
            if not _within(cwd, root):
                continue
            found[pid] = {
                "name": entry.get("name"),
                "pid": pid,
                "harness": "pi" if str(entry.get("entrypoint")) == "pi" else "claude",
                "status": entry.get("status"),
                "cwd": cwd,
            }
    return list(found.values())


def _git(checkout: str, *args: str) -> str:
    return subprocess.run(["git", "-C", checkout, *args], capture_output=True, text=True).stdout.strip()


def _default_branch(checkout: str) -> str:
    ref = _git(checkout, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
    if ref:
        return ref.removeprefix("refs/remotes/origin/")
    for branch in ("main", "master"):
        if _git(checkout, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"):
            return branch
    return "main"


def _state(checkout: str, default: str) -> tuple[bool, str]:
    branch = _git(checkout, "symbolic-ref", "--short", "--quiet", "HEAD") or "(detached)"
    dirty = bool(_git(checkout, "status", "--porcelain"))
    agents = ", ".join(s["name"] or f"pid {s['pid']}" for s in sessions_in(checkout)) or "no agent"
    line = f"{checkout}: {branch}{' · uncommitted changes' if dirty else ''} · {agents} inside"
    return branch == default and not dirty, line


def cmd_wait(args: argparse.Namespace) -> int:
    default = _default_branch(args.checkout)
    deadline = time.monotonic() + args.timeout
    last = ""
    while True:
        free, line = _state(args.checkout, default)
        if line != last:
            print(("free: " if free else "waiting: ") + line, flush=True)
            last = line
        if free:
            return 0
        if time.monotonic() >= deadline:
            print(f"timeout: after {args.timeout}s, {line}", flush=True)
            return 1
        time.sleep(args.interval)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="verb", required=True)
    listing = sub.add_parser("list")
    listing.add_argument("path")
    wait = sub.add_parser("wait")
    wait.add_argument("checkout")
    wait.add_argument("--timeout", type=int, default=900)
    wait.add_argument("--interval", type=float, default=3.0)
    args = parser.parse_args()
    if args.verb == "list":
        print(json.dumps(sessions_in(args.path), indent=2))
        return 0
    return cmd_wait(args)


if __name__ == "__main__":
    sys.exit(main())
