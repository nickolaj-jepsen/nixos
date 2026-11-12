"""Which live processes have their cwd inside a folder: what makes removing it unsafe."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Optional

from .git import is_within, run


def _ancestors() -> set[int]:
    pids: set[int] = {os.getpid()}
    pid = os.getppid()
    while pid and pid > 1:
        pids.add(pid)
        try:
            stat = Path(f"/proc/{pid}/stat").read_text()
        except OSError:
            break
        rest = stat.rsplit(")", 1)[-1].split()
        pid = int(rest[1]) if len(rest) > 1 else 0
    return pids


def _proc_cwds() -> Optional[list[tuple[int, str]]]:
    """(pid, cwd) for every readable process; None when neither /proc nor lsof can tell."""
    if os.path.isdir("/proc/self"):
        rows: list[tuple[int, str]] = []
        for entry in os.scandir("/proc"):
            if not entry.name.isdigit():
                continue
            try:
                rows.append((int(entry.name), os.readlink(os.path.join(entry.path, "cwd"))))
            except OSError:
                continue
        return rows
    if shutil.which("lsof"):
        proc = run(["lsof", "-w", "-n", "-d", "cwd", "-F", "pn"], check=False)
        if proc.returncode not in (0, 1):
            return None
        rows = []
        pid = None
        for line in proc.stdout.splitlines():
            if line.startswith("p"):
                pid = int(line[1:]) if line[1:].isdigit() else None
            elif line.startswith("n") and pid:
                rows.append((pid, line[1:]))
        return rows
    return None


def busy_pids(path: str, *, ignore_ancestors: bool = True) -> list[int]:
    """Every live process other than this one with its cwd inside `path`, its ancestors skipped by default."""
    root = os.path.realpath(path)
    ours = _ancestors() if ignore_ancestors else {os.getpid()}
    found: list[int] = []
    for pid, cwd in _proc_cwds() or []:
        if pid in ours:
            continue
        # A deleted cwd reads as "<path> (deleted)", which is_within rejects on its own.
        if is_within(os.path.realpath(cwd), root):
            found.append(pid)
    return found


def _hub_session(pid: int) -> Optional[str]:
    """The name agent-hub has for the agent session `pid` runs under, when it is installed and knows one."""
    hub = shutil.which("agent-hub")
    if not hub:
        return None
    try:
        out = subprocess.run([hub, "status", "--pid", str(pid), "--json"], capture_output=True, text=True, timeout=2)
        return json.loads(out.stdout).get("name") or None if out.stdout.strip() else None
    except (OSError, ValueError, AttributeError, subprocess.TimeoutExpired):
        return None


def describe_pid(pid: int) -> str:
    """`<command> (pid N)`, with the agent session it runs under when agent-hub knows it."""
    try:
        name = Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        try:
            name = run(["ps", "-o", "comm=", "-p", str(pid)], check=False).stdout.strip()
        except OSError:
            name = ""
    session = _hub_session(pid)
    detail = f"pid {pid}" + (f', session "{session}"' if session else "")
    return f"{os.path.basename(name)} ({detail})" if name else detail
