"""Reading Claude Code's transcript for the one thing the hub takes from it: the session's title."""

import json

from .common import folded

TITLE_CHARS = 80
# A first look reads this much of the end, not a transcript that can run to tens of megabytes.
START_BYTES = 2 << 20


class TitleTail:
    """Follows a transcript as it grows and keeps Claude Code's own name for the session:
    `/rename`'s (`custom-title`), else the one it generated (`ai-title`)."""

    def __init__(self, path):
        self.path = path
        self.title = ""
        self.custom = False
        self.offset = None
        self.partial = b""

    def advance(self):
        """Reads on; returns whether the title changed."""
        try:
            with open(self.path, "rb") as file:
                size = file.seek(0, 2)
                if self.offset is None:
                    self.offset = max(0, size - START_BYTES)
                if size < self.offset:
                    self.offset, self.partial = 0, b""
                file.seek(self.offset)
                data = file.read()
        except OSError:
            return False
        self.offset += len(data)
        lines = (self.partial + data).split(b"\n")
        self.partial = lines.pop()
        before = self.title
        for line in lines:
            if b"-title" in line:
                self._feed(line)
        return self.title != before

    def _feed(self, line):
        try:
            entry = json.loads(line)
        except ValueError:
            return
        if not isinstance(entry, dict) or entry.get("isSidechain"):
            return
        if entry.get("type") == "custom-title" and isinstance(entry.get("customTitle"), str):
            self.title, self.custom = folded(entry["customTitle"])[:TITLE_CHARS], True
        elif entry.get("type") == "ai-title" and isinstance(entry.get("aiTitle"), str) and not self.custom:
            self.title = folded(entry["aiTitle"])[:TITLE_CHARS]
