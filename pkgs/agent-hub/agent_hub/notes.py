"""Which notes a session wrote or read, for the reader and each agent's `/open plan`.

A note is Markdown under the agents' notes root, or a plan Claude's plan mode wrote. What a
session touched comes from its tool calls, in its transcript and its subagents' beside it, so
a subagent's report counts as much as the session's own. Being missed here only ranks a note
lower: the session's project folder follows the rest in `listing`.
"""

import heapq
import json
import os
import re
import threading
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from .common import shown_block

# Rendered whole and sent on one line, so a note can't grow past what the socket's line limit takes.
NOTE_MAX = 1 << 20
LIST_MAX = 40
WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "write", "edit"}
READ_TOOLS = {"Read", "read"}
SHELL_TOOLS = {"Bash", "bash", "bg_run"}
# pi's record of a write, which a nested call's transcript may not name.
RECORD = "agent-note"
FAILED = rb'"is_?[eE]rror"\s*:\s*true'
# A path right after one of these is what the command writes.
SHELL_WRITE = re.compile(r"(?:>>?|\btee(?:\s+-a)?|\b(?:mv|cp)\s+\S+)\s*[\"']?$")


def default_roots():
    home = Path.home()
    return [home / ".local/share/agents", home / ".claude/plans", home / ".claude-work/plans"]


def is_note(path, roots):
    """Whether absolute `path` is a note: Markdown under a root, minus superseded copies
    (`history/`, annotate-plan's `PLAN.prev.md`) and dot dirs."""
    if not path.endswith(".md") or os.path.basename(path) == "PLAN.prev.md":
        return False
    for root in roots:
        if path.startswith(f"{root}/"):
            parts = path[len(str(root)) + 1:].split("/")
            return not any(part == "history" or part.startswith(".") for part in parts[:-1])
    return False


def labels(paths):
    """`<dir>/<file>` for each path, with more parent dirs where two would read the same."""
    parts = [path.split("/") for path in paths]
    depth = [2] * len(paths)
    while True:
        shown = ["/".join(p[-d:]) for p, d in zip(parts, depth)]
        counts = Counter(shown)
        grown = False
        for i, name in enumerate(shown):
            if counts[name] > 1 and depth[i] < len(parts[i]):
                depth[i] += 1
                grown = True
        if not grown:
            return shown


def mtime_ms(path):
    try:
        return os.stat(path).st_mtime_ns // 1_000_000
    except OSError:
        return None


@dataclass
class Scan:
    """What one session's transcripts have said so far, and how far they have been read."""

    offsets: dict = field(default_factory=dict)
    written: Counter = field(default_factory=Counter)
    read: Counter = field(default_factory=Counter)
    # Tool call id → the tally and path it counted, undone if the call failed.
    calls: dict = field(default_factory=dict)


class Notes:
    def __init__(self, roots=None):
        self.roots = [str(root) for root in (roots or default_roots())]
        self.real_roots = [os.path.realpath(root) for root in self.roots]
        self.scans = {}
        # Session id → (its newest written note, how many notes it touched), as of its last scan.
        self.latest = {}
        self.lock = threading.Lock()
        home = str(Path.home())
        forms = [re.escape(root) for root in self.roots]
        forms += ["~" + re.escape(root[len(home):]) for root in self.roots if root.startswith(f"{home}/")]
        self.in_command = re.compile(rf"(?:{'|'.join(forms)})/[^\"'`\n<>|*;&)]{{1,200}}?\.md\b")
        # Most lines hold no note, and a transcript can pass a gigabyte, so they aren't parsed.
        tails = [root[len(home) + 1:] if root.startswith(f"{home}/") else root for root in self.roots]
        self.hints = re.compile(b"|".join([*(re.escape(tail.encode()) for tail in tails), FAILED, RECORD.encode()]))

    def _resolve(self, raw, cwd):
        """A tool's path as absolute, as pi's tools and the shell read it; None when it isn't one."""
        if not isinstance(raw, str) or not raw:
            return None
        path = os.path.expanduser(raw.removeprefix("@"))
        if not os.path.isabs(path):
            if not cwd:
                return None
            path = os.path.join(cwd, path)
        return os.path.normpath(path)

    def _count(self, scan, tally, raw, cwd, call=None):
        path = self._resolve(raw, cwd)
        if path is None or not is_note(path, self.roots):
            return
        getattr(scan, tally)[path] += 1
        if call:
            scan.calls[call] = (tally, path)

    def _undo(self, scan, call):
        tally, path = scan.calls.pop(call, (None, None))
        if tally:
            counter = getattr(scan, tally)
            counter[path] -= 1
            if counter[path] <= 0:
                del counter[path]

    def _tool(self, scan, name, args, call, cwd):
        args = args if isinstance(args, dict) else {}
        target = args.get("file_path") or args.get("path")
        if name in WRITE_TOOLS:
            self._count(scan, "written", target, cwd, call)
        elif name in READ_TOOLS:
            self._count(scan, "read", target, cwd, call)
        elif name in SHELL_TOOLS and isinstance(args.get("command"), str):
            command = args["command"]
            for match in self.in_command.finditer(command):
                tally = "written" if SHELL_WRITE.search(command[:match.start()]) else "read"
                self._count(scan, tally, match[0], cwd)

    def _entry(self, scan, entry, cwd):
        """Claude's and pi's transcripts differ only in these names."""
        if entry.get("type") == "custom" and entry.get("customType") == RECORD:
            data = entry.get("data")
            self._count(scan, "written", data.get("path") if isinstance(data, dict) else None, cwd)
            return
        message = entry.get("message")
        if not isinstance(message, dict):
            return
        if message.get("role") == "toolResult" and message.get("isError"):
            self._undo(scan, message.get("toolCallId"))
        content = message.get("content")
        for block in content if isinstance(content, list) else []:
            if not isinstance(block, dict):
                continue
            kind = block.get("type")
            if kind == "tool_use":
                self._tool(scan, block.get("name"), block.get("input"), block.get("id"), cwd)
            elif kind == "toolCall":
                self._tool(scan, block.get("name"), block.get("arguments"), block.get("id"), cwd)
            elif kind == "tool_result" and block.get("is_error"):
                self._undo(scan, block.get("tool_use_id"))

    def _read_file(self, scan, path, cwd):
        """Takes the whole lines added to one transcript since the last read."""
        offset = scan.offsets.get(path, 0)
        try:
            if os.path.getsize(path) < offset:
                offset = 0
            with open(path, "rb") as lines:
                lines.seek(offset)
                for line in lines:
                    if not line.endswith(b"\n"):
                        break
                    offset += len(line)
                    if self.hints.search(line):
                        try:
                            entry = json.loads(line)
                        except ValueError:
                            continue
                        if isinstance(entry, dict):
                            self._entry(scan, entry, cwd)
        except OSError:
            return
        scan.offsets[path] = offset

    def scan(self, sid, transcript, cwd):
        """Reads what `transcript` and its subagents added; returns whether what a row shows moved.
        Subagents' files sit in a folder named after it, `subagents/` for Claude, `tasks/` for pi."""
        if not transcript:
            return False
        with self.lock:
            scan = self.scans.setdefault(sid, Scan())
            self._read_file(scan, transcript, cwd)
            for path in Path(transcript).with_suffix("").glob("**/*.jsonl"):
                self._read_file(scan, str(path), cwd)
            written = self._dated(scan.written)
            touched = len(written) + len(self._dated(k for k in scan.read if k not in scan.written))
            newest = None
            if written:
                path, at = written[0]
                newest = {"path": path, "name": labels([path])[0], "at": at}
            summary = (newest, touched)
            moved = summary != self.latest.get(sid, (None, 0))
            self.latest[sid] = summary
            return moved

    def forget(self, sid):
        with self.lock:
            self.scans.pop(sid, None)
            self.latest.pop(sid, None)

    @staticmethod
    def _dated(paths):
        """(path, mtime) of those that still exist, newest first."""
        dated = ((path, mtime_ms(path)) for path in paths)
        return sorted(((path, at) for path, at in dated if at is not None), key=lambda item: -item[1])

    def project_of(self, path):
        """The project folder a note lies in, or None for a plan or anything else."""
        root = self.roots[0]
        return path[len(root) + 1:].split("/")[0] if path.startswith(f"{root}/") and path.count("/") > root.count("/") + 1 else None

    def _project(self, project):
        """The newest notes in the project's folder, however they got there."""
        if not project:
            return []
        found = []
        for folder, dirs, files in os.walk(os.path.join(self.roots[0], project)):
            dirs[:] = [d for d in dirs if d != "history" and not d.startswith(".")]
            found += [os.path.join(folder, name) for name in files if is_note(os.path.join(folder, name), self.roots)]
        dated = ((path, mtime_ms(path)) for path in found)
        return heapq.nlargest(LIST_MAX, ((path, at) for path, at in dated if at is not None), key=lambda item: item[1])

    def listing(self, sid, transcript, cwd, project):
        """What the session wrote, then what it read, then the rest of its project's folder, each
        newest first, as protocol's `NOTE`. A session this hub can't read lists only the folder."""
        self.scan(sid, transcript, cwd)
        with self.lock:
            scan = self.scans.get(sid) or Scan()
            written = self._dated(scan.written)[:LIST_MAX]
            read = self._dated(k for k in scan.read if k not in scan.written)[:LIST_MAX]
        seen = {path for path, _ in (*written, *read)}
        groups = (("written", written), ("read", read), ("project", [n for n in self._project(project) if n[0] not in seen]))
        rows = [(group, path, at) for group, items in groups for path, at in items]
        names = labels([path for _, path, _ in rows])
        return [{"path": path, "name": name, "group": group, "at": at} for (group, path, at), name in zip(rows, names)]

    def read(self, path, since=None):
        """A note for showing, or None when `path` isn't one or is gone. Links are resolved first,
        so one inside the notes folder can't reach out of it. `since` an unchanged note's mtime
        answers `unchanged` without reading it."""
        if not is_note(path, self.roots) or not is_note(os.path.realpath(path), self.real_roots):
            return None
        try:
            with open(path, "rb") as note:
                stat = os.fstat(note.fileno())
                at = stat.st_mtime_ns // 1_000_000
                if since == at:
                    return {"path": path, "at": at, "unchanged": True}
                data = note.read(NOTE_MAX + 1)
        except OSError:
            return None
        text = shown_block(data[:NOTE_MAX].decode(errors="replace"), NOTE_MAX)[0]
        return {"path": path, "at": at, "size": stat.st_size, "text": text, "cut": len(data) > NOTE_MAX}
