"""Which transcripts a sweep must leave alone.

A session that is still open appends to its transcript, so replacing the file
underneath it would drop whatever it wrote in between. The agent hub's session
registry lists the live ones; a file touched seconds ago is treated as live too,
because a session can outlive its registry entry and a rewrite is irreversible.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

REGISTRIES = ("~/.claude/sessions", "~/.claude-work/sessions")

# Modified this recently and not in the registry: assume something is writing it.
RECENT_SECONDS = 120


def _alive(pid: object) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def live_session_ids() -> set[str]:
    """Session ids whose agent process is still running."""
    ids: set[str] = set()
    for pattern in REGISTRIES:
        for path in Path(pattern).expanduser().glob("*.json"):
            try:
                entry = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if not isinstance(entry, dict):
                continue
            session_id = entry.get("sessionId")
            if isinstance(session_id, str) and _alive(entry.get("pid")):
                ids.add(session_id)
    return ids


def is_live(path: Path, live: set[str], session_id: str | None = None) -> bool:
    if path.stem in live or (session_id is not None and session_id in live):
        return True
    try:
        modified = os.stat(path).st_mtime
    except OSError:
        return True
    return time.time() - modified < RECENT_SECONDS
