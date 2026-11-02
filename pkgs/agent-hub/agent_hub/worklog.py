"""The work log: one JSON line per turn that got an ending, across every session, kept in
the state dir so `agent-hub log` and `find` read it without the daemon.

A line: `{at, session, agent, cwd, configDir, label, state, did, ask}`, `at` in ms.
"""

import json
import re
import time
from datetime import datetime, timedelta

from .common import json_lines, write_atomic

KEEP_DAYS = 90
DAY_MS = 86_400_000


def append(path, line):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as out:
            out.write(json.dumps(line) + "\n")
    except OSError:
        pass


def read(path, since=0):
    """The lines at or after `since` (ms), oldest first; unreadable lines are skipped."""
    try:
        return [line for line in json_lines(path) if (line.get("at") or 0) >= since]
    except OSError:
        return []


def prune(path, now):
    """Drops lines older than `KEEP_DAYS`, rewriting the file only when there are any."""
    cutoff = now - KEEP_DAYS * DAY_MS
    try:
        with open(path, encoding="utf-8", errors="replace") as log:
            first = log.readline()
        if (json.loads(first).get("at") or 0) >= cutoff:
            return
    except (OSError, ValueError, AttributeError):
        return
    try:
        write_atomic(path, "".join(json.dumps(line) + "\n" for line in read(path, cutoff)))
    except OSError:
        pass


def since_ms(text, now=None):
    """`1d`, `3h`, `2w`, `today`, `yesterday` or an ISO date, as ms since the epoch."""
    now = time.time() if now is None else now / 1000
    text = text.strip().lower()
    midnight = datetime.fromtimestamp(now).replace(hour=0, minute=0, second=0, microsecond=0)
    if text == "today":
        return int(midnight.timestamp() * 1000)
    if text == "yesterday":
        return int((midnight - timedelta(days=1)).timestamp() * 1000)
    match = re.fullmatch(r"(\d+)\s*([hdw])", text)
    if match:
        hours = int(match.group(1)) * {"h": 1, "d": 24, "w": 168}[match.group(2)]
        return int((now - hours * 3600) * 1000)
    return int(datetime.fromisoformat(text).timestamp() * 1000)


def by_session(lines):
    """Lines grouped by session, each group oldest first, groups by their latest line."""
    groups = {}
    for line in lines:
        groups.setdefault(line.get("session"), []).append(line)
    return sorted(groups.values(), key=lambda group: group[-1].get("at") or 0)


def matches(group, words):
    """Whether every word is in the group's labels, did-lines or asks, ignoring case."""
    text = " ".join(f"{line.get('label') or ''} {line.get('did') or ''} {line.get('ask') or ''}" for line in group).lower()
    return all(word.lower() in text for word in words)
