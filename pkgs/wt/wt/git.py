"""Process and git helpers, plus the one fatal-error path every verb uses."""

from __future__ import annotations

import os
import subprocess
import sys
from typing import NoReturn, Optional


def die(message: str) -> NoReturn:
    print(f"wt: {message}", file=sys.stderr)
    raise SystemExit(1)


def info(message: str) -> None:
    print(f"wt: {message}", file=sys.stderr)


def run(
    args: list[str],
    cwd: Optional[str] = None,
    *,
    input_text: Optional[str] = None,
    check: bool = True,
    env: Optional[dict[str, str]] = None,
) -> subprocess.CompletedProcess:
    full_env = os.environ.copy()
    full_env.setdefault("GIT_TERMINAL_PROMPT", "0")
    # A rebase --continue must never wait on an editor.
    full_env.setdefault("GIT_EDITOR", "true")
    if env:
        full_env.update(env)
    proc = subprocess.run(
        args,
        cwd=cwd,
        input=input_text,
        text=True,
        errors="replace",
        capture_output=True,
        env=full_env,
    )
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        die(f"{' '.join(args)} failed" + (f": {detail}" if detail else ""))
    return proc


def git(cwd: Optional[str], *args: str, check: bool = True, input_text: Optional[str] = None) -> str:
    return run(["git", "-C", cwd or ".", *args], input_text=input_text, check=check).stdout


def git_ok(cwd: Optional[str], *args: str) -> bool:
    return run(["git", "-C", cwd or ".", *args], check=False).returncode == 0


def normpath(path: str, base: Optional[str] = None) -> str:
    """Lexically normalise a path that need not exist yet (no symlink resolution)."""
    if not os.path.isabs(path):
        path = os.path.join(base or os.getcwd(), path)
    return os.path.normpath(path)


def is_within(path: str, root: str) -> bool:
    path, root = normpath(path), normpath(root)
    return path == root or path.startswith(root + os.sep)
