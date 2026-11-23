"""Ghostty-style scrollback search for kitty, run as `map <key> kitten <this file>`.

The overlay redraws the window's scrollback with its own colours, so it looks
like the terminal itself, with a floating search box in the top-right corner.
All matches are highlighted and the selected one stands out. Enter goes to the
next (older) match, Shift+Enter to the previous one, and Escape closes the
search, leaving the real window scrolled to where the overlay was.

Arguments: `key=RRGGBB` colour overrides (see COLORS), then optional text to
prefill (kitty substitutes `@selection` with the current selection).
"""

from __future__ import annotations

import re
import sys
from bisect import bisect_left, bisect_right
from typing import Any

from kittens.tui.handler import Handler, result_handler
from kittens.tui.line_edit import LineEdit
from kittens.tui.loop import EventType as MouseEventType
from kittens.tui.loop import Loop, MouseButton, MouseEvent
from kittens.tui.operations import MouseTracking
from kitty.fast_data_types import truncate_point_for_length, wcswidth
from kitty.key_encoding import SHIFT, EventType, KeyEvent

# Defaults are Ghostty's search highlight colours; the nix module passes the theme's.
COLORS = {
    "match_fg": "000000",
    "match_bg": "FFE082",
    "current_fg": "000000",
    "current_bg": "F2A57E",
    "box_fg": "DAD8CE",
    "box_muted": "878580",
    "field_bg": "343331",
    "error": "D14D41",
}
BOX_WIDTH = 46
BOX_ROWS = 3
WHEEL_LINES = 3
USER_VAR = "kitty_search"

SGR = re.compile(r"(\x1b\[[0-9;:]*m)")
# Everything kitty's ANSI dump can contain besides SGR: OSC (hyperlinks, prompt
# marks), other CSI and DCS sequences.
NON_SGR = re.compile(
    r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;:?<>=]*[ -/]*[@-ln-~]|\x1bP[^\x1b]*\x1b\\"
)
ROW_SEP = re.compile(r"(\r\n|\r|\n)")


def fg(hex6: str) -> str:
    return f"38;2;{int(hex6[0:2], 16)};{int(hex6[2:4], 16)};{int(hex6[4:6], 16)}"


def bg(hex6: str) -> str:
    return f"48;2;{int(hex6[0:2], 16)};{int(hex6[2:4], 16)};{int(hex6[4:6], 16)}"


def sgr(*codes: str) -> str:
    return "\x1b[" + ";".join(codes) + "m"


def fit(text: str, cells: int) -> str:
    """Truncate *text* to at most *cells* columns, then pad it to exactly that."""
    text = text[: truncate_point_for_length(text, cells)]
    return text + " " * (cells - wcswidth(text))


class Scrollback:
    """Rows as kitty shows them, plus one search string of the logical lines."""

    def __init__(self, dump: str) -> None:
        # The dump ends every row with \r\n, or a bare \r for a soft-wrapped row.
        parts = ROW_SEP.split(dump)
        self.raw: list[str] = [NON_SGR.sub("", p) for p in parts[0::2]]
        seps = parts[1::2]
        if len(self.raw) > len(seps) and self.raw[-1] == "":
            self.raw.pop()
        self.wrapped = [i < len(seps) and seps[i] == "\r" for i in range(len(self.raw))]
        self.plain = [SGR.sub("", r) for r in self.raw]
        self.row_starts: list[int] = []
        chunks: list[str] = []
        pos = 0
        for row, wrapped in zip(self.plain, self.wrapped):
            self.row_starts.append(pos)
            chunks.append(row)
            pos += len(row)
            if not wrapped:
                chunks.append("\n")
                pos += 1
        self.text = "".join(chunks)

    def __len__(self) -> int:
        return len(self.raw)

    def row_of(self, offset: int) -> int:
        return bisect_right(self.row_starts, offset) - 1

    def row_spans(self, start: int, end: int) -> list[tuple[int, int, int]]:
        """Split a match into (row, start column, end column) pieces."""
        spans = []
        row = self.row_of(start)
        while start < end and row < len(self.raw):
            row_start = self.row_starts[row]
            stop = min(end, row_start + len(self.plain[row]))
            if stop > start:
                spans.append((row, start - row_start, stop - row_start))
            row += 1
            if row < len(self.raw):
                start = self.row_starts[row]
        return spans


def render_row(raw: str, spans: list[tuple[int, int, str]]) -> str:
    """Re-emit a row's own SGR, overriding colours inside the highlighted spans."""
    if not spans:
        return raw
    out: list[str] = []
    state: list[str] = []
    col = 0
    i = 0
    active = ""
    for token in SGR.split(raw):
        if token.startswith("\x1b["):
            state = [] if token in ("\x1b[m", "\x1b[0m") else [*state, token]
            if not active:
                out.append(token)
            continue
        for ch in token:
            while i < len(spans) and spans[i][1] <= col:
                i += 1
            want = spans[i][2] if i < len(spans) and spans[i][0] <= col else ""
            if want != active:
                out.append("\x1b[m" + (want or "".join(state)))
                active = want
            out.append(ch)
            col += 1
    if active:
        out.append("\x1b[m")
    return "".join(out)


class Search(Handler):
    mouse_tracking = MouseTracking.buttons_only
    overlay_ready_report_needed = True

    def __init__(self, buf: Scrollback, colors: dict[str, str], prefill: str) -> None:
        self.buf = buf
        self.c = colors
        self.match_sgr = sgr(fg(colors["match_fg"]), bg(colors["match_bg"]))
        self.current_sgr = sgr(fg(colors["current_fg"]), bg(colors["current_bg"]), "1")
        self.edit = LineEdit()
        self.edit.add_text(prefill)
        # Like re-focusing Ghostty's search field: the next keystroke replaces the text.
        self.select_all = bool(prefill)
        self.matches: list[tuple[int, int]] = []
        self.starts: list[int] = []
        self.current = -1
        self.top = 0
        self.initial_top = 0
        self.buttons: dict[int, str] = {}
        self.result: str | None = None

    @property
    def rows(self) -> int:
        return self.screen_size.rows

    @property
    def cols(self) -> int:
        return self.screen_size.cols

    def initialize(self) -> None:
        # Lets the kitty map hand the start-search key to this overlay instead of
        # opening a second search on top of it.
        self.write(f"\x1b]1337;SetUserVar={USER_VAR}=MQ==\x07")
        self.write(
            "\x1b[?7l"
        )  # no autowrap: a row wider than a resized window must not scroll
        self.top = self.initial_top = self.max_top()
        self.research()
        self.draw()

    def on_resize(self, new_size: Any) -> None:
        super().on_resize(new_size)
        self.scroll_to(self.top)
        self.draw()

    # ---- searching -------------------------------------------------------

    def research(self) -> None:
        pattern = self.edit.current_input
        if pattern:
            rx = re.compile(re.escape(pattern), re.IGNORECASE)
            self.matches = [m.span() for m in rx.finditer(self.buf.text)]
        else:
            self.matches = []
        self.starts = [s for s, _ in self.matches]
        if not self.matches:
            self.current = -1
            return
        # Select the newest match above the bottom of the view, so refining the
        # pattern stays near what is on screen.
        bottom_row = self.top + self.rows
        bottom = (
            self.buf.row_starts[bottom_row]
            if bottom_row < len(self.buf)
            else len(self.buf.text)
        )
        self.current = max(0, bisect_left(self.starts, bottom) - 1)
        self.reveal()

    def step(self, delta: int) -> None:
        if self.matches:
            self.current = (self.current + delta) % len(self.matches)
            self.reveal()

    def reveal(self) -> None:
        row = self.buf.row_of(self.starts[self.current])
        if not self.top + BOX_ROWS <= row < self.top + self.rows:
            self.scroll_to(row - self.rows // 2)

    # ---- viewport --------------------------------------------------------

    def max_top(self) -> int:
        return max(0, len(self.buf) - self.rows)

    def scroll_to(self, top: int) -> None:
        self.top = max(0, min(top, self.max_top()))

    # ---- input -----------------------------------------------------------

    def close(self) -> None:
        if self.matches or self.top != self.initial_top:
            self.result = str(max(0, len(self.buf) - self.top - self.rows))
        self.quit_loop(0)

    def on_interrupt(self) -> None:
        self.close()

    def on_text(self, text: str, _in_bracketed_paste: bool = False) -> None:
        lines = text.splitlines()
        if not lines or not lines[0]:
            return
        if self.select_all:
            self.edit.clear()
            self.select_all = False
        self.edit.add_text(lines[0])
        self.research()
        self.draw()

    def on_key_event(
        self, key_event: KeyEvent, in_bracketed_paste: bool = False
    ) -> None:
        if key_event.type is EventType.RELEASE:
            return
        if key_event.text and not key_event.mods_without_locks & ~SHIFT:
            self.on_text(key_event.text, in_bracketed_paste)
            return
        k = key_event.matches
        page = max(1, self.rows - 1)
        if k("escape") or k("ctrl+c"):
            self.close()
            return
        if k("enter") or k("up") or k("ctrl+p"):
            self.step(-1)
        elif k("shift+enter") or k("down") or k("ctrl+n"):
            self.step(1)
        elif k("page_up") or k("shift+page_up") or k("ctrl+shift+page_up"):
            self.scroll_to(self.top - page)
        elif k("page_down") or k("shift+page_down") or k("ctrl+shift+page_down"):
            self.scroll_to(self.top + page)
        elif k("ctrl+shift+up"):
            self.scroll_to(self.top - 1)
        elif k("ctrl+shift+down"):
            self.scroll_to(self.top + 1)
        elif k("ctrl+shift+home"):
            self.scroll_to(0)
        elif k("ctrl+shift+end"):
            self.scroll_to(self.max_top())
        elif k("ctrl+shift+f"):
            self.select_all = bool(self.edit.current_input)
        elif not self.edit_key(key_event):
            return
        self.draw()

    def edit_key(self, key_event: KeyEvent) -> bool:
        before = self.edit.current_input
        k = key_event.matches
        if self.select_all and (k("backspace") or k("delete")):
            self.edit.clear()
        elif k("ctrl+u"):
            self.edit.clear()
        elif k("ctrl+w") or k("ctrl+backspace") or k("alt+backspace"):
            head, tail = self.edit.split_at_cursor()
            stripped = head.rstrip()
            head = stripped[: max(stripped.rfind(" "), stripped.rfind("/")) + 1]
            self.edit.clear()
            self.edit.add_text(head)
            self.edit.current_input += tail
        elif not self.edit.on_key(key_event):
            return False
        self.select_all = False
        if self.edit.current_input != before:
            self.research()
        return True

    def on_mouse_event(self, mouse_event: MouseEvent) -> None:
        wheel = {
            MouseButton.WHEEL_UP: -WHEEL_LINES,
            MouseButton.WHEEL_DOWN: WHEEL_LINES,
        }.get(mouse_event.buttons)
        if mouse_event.type is MouseEventType.PRESS and wheel:
            self.scroll_to(self.top + wheel)
            self.draw()
        else:
            super().on_mouse_event(mouse_event)

    def on_click(self, mouse_event: MouseEvent) -> None:
        if mouse_event.cell_y != 1:
            return
        action = self.buttons.get(mouse_event.cell_x)
        if action == "close":
            self.close()
        elif action:
            self.step(-1 if action == "older" else 1)
            self.draw()

    # ---- drawing ---------------------------------------------------------

    def visible_spans(self) -> dict[int, list[tuple[int, int, str]]]:
        spans: dict[int, list[tuple[int, int, str]]] = {}
        if not self.matches:
            return spans
        last = self.top + self.rows
        lo = (
            self.buf.row_starts[self.top]
            if self.top < len(self.buf)
            else len(self.buf.text)
        )
        hi = (
            self.buf.row_starts[last]
            if last < len(self.buf)
            else len(self.buf.text) + 1
        )
        i = max(
            0, bisect_left(self.starts, lo) - 1
        )  # the one before may wrap into view
        while i < len(self.matches) and self.starts[i] < hi:
            colour = self.current_sgr if i == self.current else self.match_sgr
            for row, start, end in self.buf.row_spans(*self.matches[i]):
                if self.top <= row < last:
                    spans.setdefault(row, []).append((start, end, colour))
            i += 1
        return spans

    @Handler.atomic_update
    def draw(self) -> None:
        out = ["\x1b[?25l"]
        spans = self.visible_spans()
        for y in range(self.rows):
            row = self.top + y
            out.append(f"\x1b[{y + 1};1H\x1b[m\x1b[2K")
            if row < len(self.buf):
                out.append(render_row(self.buf.raw[row], spans.get(row, [])))
        out.append("\x1b[m")
        out.append(self.draw_box())
        self.write("".join(out))

    def draw_box(self) -> str:
        c = self.c
        width = min(BOX_WIDTH, self.cols - 2)
        field = width - 19
        if field < 4:
            return ""
        x = self.cols - width - 1  # 0-based column, one cell clear of the edge
        border = sgr(fg(c["box_muted"]))

        pattern = self.edit.current_input
        if self.matches:
            counter = f"{len(self.matches) - self.current}/{len(self.matches)}"
            counter_sgr = sgr(fg(c["box_muted"]))
        else:
            counter = "0/0" if pattern else ""
            counter_sgr = sgr(fg(c["error"]))

        # Keep the cursor inside the field, dropping text off the left if needed.
        head, tail = self.edit.split_at_cursor()
        while head and wcswidth(head) > field - 1:
            head = head[1:]
        cursor_x = x + 2 + wcswidth(head)
        field_bg = bg(c["field_bg"])
        if not pattern:
            entry = sgr(fg(c["box_muted"]), field_bg) + fit(" Search", field)
            cursor_x = x + 2
        else:
            shown = fit(head + tail, field).rstrip(" ")
            highlight = "7;" if self.select_all else ""
            entry = (
                sgr(highlight + fg(c["box_fg"]), field_bg)
                + shown
                + sgr("27")
                + " " * (field - wcswidth(shown))
            )

        buttons_x = x + 2 + field + 1 + 7 + 1
        self.buttons = {
            buttons_x + 1: "older",
            buttons_x + 3: "newer",
            buttons_x + 5: "close",
        }
        middle = (
            f"{border}│\x1b[m {entry}\x1b[m {counter_sgr}{counter.rjust(7)}\x1b[m "
            f"{sgr(fg(c['box_fg']))} ↑ ↓ ✕ {border}│"
        )
        rows = [
            border + "╭" + "─" * (width - 2) + "╮",
            middle,
            border + "╰" + "─" * (width - 2) + "╯",
        ]
        out = [f"\x1b[{y + 1};{x + 1}H{r}\x1b[m" for y, r in enumerate(rows)]
        out.append(f"\x1b[2;{cursor_x + 1}H\x1b[6 q\x1b[?25h")
        return "".join(out)


def main(args: list[str]) -> str | None:
    colors = dict(COLORS)
    prefill = ""
    for arg in args[1:]:
        key, sep, value = arg.partition("=")
        if sep and key in colors:
            colors[key] = value.lstrip("#")
        elif arg != "@selection" and arg.strip():
            prefill = arg.strip().splitlines()[0]
    handler = Search(Scrollback(sys.stdin.read()), colors, prefill)
    Loop().loop(handler)
    return handler.result


@result_handler(type_of_input="screen-ansi-history", has_ready_notification=True)
def handle_result(
    _args: list[str], answer: str | None, target_window_id: int, boss: Any
) -> None:
    w = boss.window_id_map.get(target_window_id)
    if w is None or answer is None or not w.screen.is_main_linebuf():
        return
    # Rows older than the history buffer come from the pager history and
    # cannot be scrolled to; clamp to the top.
    target = min(int(answer), w.screen.historybuf.count)
    w.scroll_end()
    if target:
        w.screen.scroll(target, True)
