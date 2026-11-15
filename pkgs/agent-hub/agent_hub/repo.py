"""The repository a session works in, named once when it is first seen."""

import asyncio
import os
import subprocess

GIT_TIMEOUT = 2


def project_name(git, cwd):
    """The main checkout's folder name, which every worktree of a repository shares, or the
    directory's own name outside git."""
    try:
        out = subprocess.run([git or "git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                             capture_output=True, text=True, timeout=GIT_TIMEOUT)
        common = out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        common = ""
    return os.path.basename(os.path.dirname(common) if common.endswith("/.git") else common or cwd.rstrip("/"))


async def project(git, cwd):
    return await asyncio.to_thread(project_name, git, cwd)
