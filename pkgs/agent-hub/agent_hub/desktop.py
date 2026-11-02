"""The desktop layer: niri's windows and focus."""

import asyncio
import json
import os
import sys
from pathlib import Path

from .common import LINE_MAX, nearest

RETRY = 2.0


def niri_socket():
    """The compositor's socket: NIRI_SOCKET while it still exists, else the newest
    niri socket in the runtime dir. A unit started at login beside niri can miss the
    variable, since niri names its socket after its own pid and imports it later."""
    configured = os.environ.get("NIRI_SOCKET")
    if configured and Path(configured).exists():
        return configured
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")
    try:
        sockets = sorted(runtime.glob("niri.*.sock"), key=lambda path: path.stat().st_mtime, reverse=True)
    except OSError:
        return None
    return str(sockets[0]) if sockets else None


def niri_env():
    """The environment `niri msg` needs: it finds its compositor by NIRI_SOCKET alone."""
    env = dict(os.environ)
    socket = niri_socket()
    if socket:
        env["NIRI_SOCKET"] = socket
    else:
        env.pop("NIRI_SOCKET", None)
    return env


class Niri:
    """Window ↔ pid map and the focused window, from `niri msg --json event-stream`.
    Without a `command` there are no windows: a headless hub."""

    def __init__(self, command, on_change):
        self.command = command
        self.on_change = on_change
        self.windows = {}
        self.focused = None
        # Why the last event stream ended, so a stream that never connects is said once.
        self.lost = None

    async def run(self):
        while self.command:
            heard = False
            try:
                proc = await asyncio.create_subprocess_exec(
                    self.command, "msg", "--json", "event-stream",
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, limit=LINE_MAX, env=niri_env(),
                )
                async for line in proc.stdout:
                    heard = True
                    try:
                        self._event(json.loads(line))
                    except (ValueError, TypeError, KeyError, AttributeError):
                        continue
                await proc.wait()
            except OSError as error:
                self._lost(f"can't run {self.command}: {error}")
            # A stream that never reported a window never found the compositor.
            if heard:
                self.lost = None
            else:
                self._lost(f"no niri event stream (NIRI_SOCKET={niri_socket() or 'unset'})")
            self.windows, self.focused = {}, None
            self.on_change()
            await asyncio.sleep(RETRY)

    def _lost(self, message):
        """Says why the compositor went missing, once per reason rather than every retry."""
        if message != self.lost:
            self.lost = message
            print(f"agent-hub: {message}", file=sys.stderr)

    def _event(self, event):
        before = (dict(self.windows), self.focused)
        if "WindowsChanged" in event:
            windows = event["WindowsChanged"]["windows"]
            self.windows = {w["id"]: w.get("pid") for w in windows}
            self.focused = next((w["id"] for w in windows if w.get("is_focused")), None)
        elif "WindowOpenedOrChanged" in event:
            window = event["WindowOpenedOrChanged"]["window"]
            self.windows[window["id"]] = window.get("pid")
            if window.get("is_focused"):
                self.focused = window["id"]
        elif "WindowClosed" in event:
            self.windows.pop(event["WindowClosed"]["id"], None)
            if self.focused == event["WindowClosed"]["id"]:
                self.focused = None
        elif "WindowFocusChanged" in event:
            self.focused = event["WindowFocusChanged"]["id"]
        # Most events are title changes, which move no pid and no focus.
        if (self.windows, self.focused) != before:
            self.on_change()

    def window_of(self, pid):
        # No windows (a headless hub) means no ancestor walk, which is a `ps` per step off Linux.
        if not self.windows:
            return None
        return nearest(pid, {p: w for w, p in self.windows.items() if p})

    async def _action(self, *args):
        if not self.command:
            return
        proc = await asyncio.create_subprocess_exec(
            self.command, "msg", "action", *args,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL, env=niri_env(),
        )
        await proc.wait()

    async def spawn(self, argv):
        """Runs `argv` as niri would from a bind, so it gets the session's environment."""
        await self._action("spawn", "--", *argv)

    async def focus(self, window):
        await self._action("focus-window", "--id", str(window))
