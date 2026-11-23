"""Incremental scrollback search for kitty, run as `map <key> kitten <this file>`.

Shows the window's scrollback in an overlay with a search bar. Enter closes the
overlay and scrolls the real window so the current match sits mid-screen.

Adapted from https://github.com/Mobinshahidi/kitty-search (bce4fe7),
MIT License, Copyright (c) 2026 Mobin shahidi.
"""

from __future__ import annotations

import os
import re
import select
import shutil
import sys
import termios
import tty
from typing import Any

from kittens.tui.handler import result_handler

MAX_PATTERN_LENGTH = 200

CSI = "\x1b["
RESET = CSI + "m"
BAR = CSI + "48;5;236;38;5;255m"
MATCH = CSI + "48;5;58;38;5;255m"
CURRENT = CSI + "48;5;220;38;5;16m"
NO_MATCH = CSI + "38;5;196m"

KEYS = {
    "\x1b": "esc",
    "\r": "enter",
    "\n": "enter",
    "\t": "tab",
    "\x7f": "backspace",
    "\x08": "backspace",
    "\x17": "ctrl+w",
    "\x15": "ctrl+u",
    "\x0e": "next",  # ctrl+n
    "\x10": "prev",  # ctrl+p
    "\x1b[A": "prev",
    "\x1bOA": "prev",
    "\x1b[B": "next",
    "\x1bOB": "next",
    "\x1b[5~": "pgup",
    "\x1b[6~": "pgdn",
}


def split_rows(text: str) -> list[str]:
    # 'screen' input keeps wrap markers: rows end in \r\n, soft-wrapped rows
    # in a bare \r. Splitting on both yields one entry per on-screen row, so a
    # row's distance from the end equals the window's scroll offset.
    rows = re.split(r"\r\n|\r|\n", text)
    if rows and rows[-1] == "":
        rows.pop()
    return rows


class Search:
    def __init__(self, rows: list[str]) -> None:
        self.rows = rows
        self.pattern = ""
        self.regex = False
        self.matches: list[int] = []
        self.current = -1
        self.cols, self.height = shutil.get_terminal_size()
        self.top = max(0, len(rows) - self.view_rows)

    @property
    def view_rows(self) -> int:
        return max(1, self.height - 1)

    def compiled(self) -> re.Pattern[str] | None:
        if not self.pattern:
            return None
        # Smart case: an uppercase letter makes the search case-sensitive.
        flags = 0 if any(c.isupper() for c in self.pattern) else re.IGNORECASE
        try:
            return re.compile(
                self.pattern if self.regex else re.escape(self.pattern), flags
            )
        except re.error:
            return None

    def research(self) -> None:
        rx = self.compiled()
        self.matches = [i for i, row in enumerate(self.rows) if rx and rx.search(row)]
        # Start at the match nearest the prompt, like a terminal's own search.
        self.current = len(self.matches) - 1
        self.reveal()

    def step(self, delta: int) -> None:
        if self.matches:
            self.current = (self.current + delta) % len(self.matches)
            self.reveal()

    def reveal(self) -> None:
        if self.current >= 0:
            self.scroll_to(self.matches[self.current] - self.view_rows // 2)

    def scroll_to(self, top: int) -> None:
        self.top = max(0, min(top, len(self.rows) - self.view_rows))

    def handle(self, key: str) -> bool:
        """Apply one key; False ends the loop."""
        k = KEYS.get(key, key)
        if k == "esc":
            self.current = -1
            return False
        if k == "enter":
            return False
        if k == "next":
            self.step(1)
        elif k == "prev":
            self.step(-1)
        elif k == "pgup":
            self.scroll_to(self.top - self.view_rows)
        elif k == "pgdn":
            self.scroll_to(self.top + self.view_rows)
        elif k == "tab":
            self.regex = not self.regex
            self.research()
        elif k == "backspace":
            self.pattern = self.pattern[:-1]
            self.research()
        elif k == "ctrl+w":
            stripped = self.pattern.rstrip()
            self.pattern = stripped[: stripped.rfind(" ") + 1]
            self.research()
        elif k == "ctrl+u":
            self.pattern = ""
            self.research()
        elif len(k) == 1 and k.isprintable() and len(self.pattern) < MAX_PATTERN_LENGTH:
            self.pattern += k
            self.research()
        return True

    def render(self, out: Any) -> None:
        self.cols, self.height = shutil.get_terminal_size()
        self.scroll_to(self.top)
        rx = self.compiled()
        match_set = set(self.matches)
        current_row = self.matches[self.current] if self.current >= 0 else -1
        buf = [CSI + "?25l" + CSI + "H"]
        for screen_row in range(self.view_rows):
            i = self.top + screen_row
            text = self.rows[i][: self.cols] if i < len(self.rows) else ""
            buf.append(f"{CSI}{screen_row + 1};1H{RESET}{CSI}2K")
            if rx and i in match_set:
                colour = CURRENT if i == current_row else MATCH
                pos = 0
                for m in rx.finditer(text):
                    if m.end() > m.start():
                        buf.append(text[pos : m.start()] + colour + m.group() + RESET)
                        pos = m.end()
                buf.append(text[pos:])
            else:
                buf.append(text)
        counter = (
            f"[{self.current + 1}/{len(self.matches)}]" if self.matches else "[0/0]"
        )
        suffix = f"{counter} {'R' if self.regex else 'L'}"
        if self.pattern and not self.matches:
            suffix = NO_MATCH + suffix + BAR
        width = max(0, self.cols - len(counter) - 5)
        pattern = (
            self.pattern
            if len(self.pattern) <= width
            else "…" + self.pattern[-(width - 1) :]
        )
        left = "/ " + pattern
        pad = max(1, self.cols - len(left) - len(counter) - 2)
        buf.append(f"{CSI}{self.height};1H{BAR}{CSI}2K{left}{' ' * pad}{suffix}{RESET}")
        buf.append(f"{CSI}{self.height};{len(left) + 1}H{CSI}?25h")
        out.write("".join(buf))
        out.flush()


def read_key(fd: int) -> str:
    data = os.read(fd, 64).decode("utf-8", errors="replace")
    if data == "\x1b" and select.select([fd], [], [], 0.05)[0]:
        data += os.read(fd, 64).decode("utf-8", errors="replace")
    return data


def main(_args: list[str]) -> str | None:
    rows = split_rows(sys.stdin.read())
    search = Search(rows)
    with open("/dev/tty", "r+b", buffering=0) as raw, open("/dev/tty", "w") as out:
        fd = raw.fileno()
        old = termios.tcgetattr(fd)
        out.write(CSI + "?1049h")
        tty.setraw(fd)
        try:
            search.render(out)
            while True:
                key = read_key(fd)
                # Pasted or fast-typed text arrives as one read: feed it per char.
                keys = [key] if key in KEYS or key.startswith("\x1b") else list(key)
                if not all(search.handle(k) for k in keys):
                    break
                search.render(out)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
            out.write(RESET + CSI + "?25h" + CSI + "?1049l")
            out.flush()
    if search.current < 0:
        return None
    return str(len(rows) - 1 - search.matches[search.current])


@result_handler(type_of_input="screen-history")
def handle_result(
    _args: list[str], answer: str | None, target_window_id: int, boss: Any
) -> None:
    w = boss.window_id_map.get(target_window_id)
    if w is None or not answer or not w.screen.is_main_linebuf():
        return
    screen = w.screen
    # Rows older than the history buffer come from the pager history and
    # cannot be scrolled to; clamp to the top.
    target = min(max(0, int(answer) - screen.lines // 2), screen.historybuf.count)
    w.scroll_end()
    if target:
        screen.scroll(target, True)
