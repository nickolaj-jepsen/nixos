"""The work log: one JSON line per turn that got an ending, across every session, kept in
the state dir so `agent-hub log` and `find` read it without the daemon.

A line: `{at, session, agent, cwd, configDir, label, state, did, ask}`, `at` in ms, with what
the verdict was made of: `turn`, `candidate` (the closing words held an ask), `word` (the
model's, empty without one), `prompt` (`judge.VERSION`) and `reply` (the answer it predicted).
A line with `wrong` is you flagging the verdict it names from the popout, one with `unopened`
a `needs-reply` you dismissed without going to it, a weaker sign, and one with `answered` a
permission prompt you settled at the bar, never saying what it asked: none is a turn's ending.
A line with `peer` is the ending of a turn another session's message woke it for.

A line with `next` is what you did after `turn` (`next_prompt`), derived and never your words.

A line with `job` is a command that ran for a while: its first words only (`job_key`), and `ms`.
If it ran long enough to get an estimate, `left` and `after` say what that said and when.
"""

import difflib
import json
import re
import time
from datetime import datetime, timedelta

from .common import json_lines, write_atomic

KEEP_DAYS = 90
DAY_MS = 86_400_000
# How a prompt that pushes back opens. Narrow on purpose: a correction missed is only a `moved-on`.
CORRECTION = re.compile(
    r"^\W*(no\b|nope\b|wrong\b|that'?s not\b|not what\b|don'?t\b|stop\b|why did\b|you (didn'?t|forgot|missed)\b"
    r"|it (still|doesn'?t)\b|still (not|broken|fails?)\b|didn'?t work\b)",
    re.I,
)


def job_key(line):
    """What tells one command from another, without the arguments a secret could be in."""
    words = [word for word in str(line).split() if "=" not in word]
    return " ".join(words[:2])


def job_line(session_fields, finished, now):
    """A work log line for a finished command: the estimate it got, if any, beside what it took."""
    estimate = finished.get("estimate") or {}
    line = {"at": now, **session_fields, "job": job_key(finished["line"]), "ms": finished["ms"]}
    if estimate.get("left") is not None:
        line.update({"left": estimate["left"], "after": estimate["after"]})
    return line


def past_minutes(path, command, keep=5):
    """How long the latest runs of a command took, in whole minutes, oldest first."""
    key = job_key(command)
    return [line["ms"] // 60_000 for line in read(path) if line.get("job") == key][-keep:]


def estimate_errors(path):
    """How far each estimate was from what the command then took, in minutes."""
    return [abs(line["left"] - (line["ms"] - line["after"]) / 60_000) for line in read(path) if line.get("left") is not None and "after" in line]


def next_prompt(outcome, prompt):
    """What your next prompt says of a turn that ended with `outcome` (None: it was cut short,
    unread): how it reads, its length, and how close it came to the reply predicted."""
    if outcome is None:
        kind = "interrupted"
    elif CORRECTION.match(prompt):
        kind = "corrected"
    else:
        kind = "answered" if outcome.get("state") == "blocked" else "moved-on"
    line = {"next": kind, "words": len(prompt.split())}
    predicted = (outcome or {}).get("reply")
    if predicted:
        line["replyMatch"] = round(difflib.SequenceMatcher(None, predicted.lower(), prompt.lower()).ratio(), 2)
    return line


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
