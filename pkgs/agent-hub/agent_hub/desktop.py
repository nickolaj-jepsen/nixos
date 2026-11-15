"""The desktop layer: the compositor's windows and focus, from niri."""

import asyncio
import json
import os
import sys
from pathlib import Path

from .common import LINE_MAX, nearest

RETRY = 2.0


def runtime_dir():
    return Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")


def niri_socket():
    """The compositor's socket: NIRI_SOCKET while it still exists, else the newest
    niri socket in the runtime dir. A unit started at login beside niri can miss the
    variable, since niri names its socket after its own pid and imports it later."""
    configured = os.environ.get("NIRI_SOCKET")
    if configured and Path(configured).exists():
        return configured
    try:
        sockets = sorted(runtime_dir().glob("niri.*.sock"), key=lambda path: path.stat().st_mtime, reverse=True)
    except OSError:
        return None
    return str(sockets[0]) if sockets else None


def niri_env():
    """The environment `niri msg` needs: it finds its compositor by NIRI_SOCKET alone."""
    env = dict(os.environ)
    path = niri_socket()
    if path:
        env["NIRI_SOCKET"] = path
    else:
        env.pop("NIRI_SOCKET", None)
    return env


class Niri:
    """niri, through `niri msg`."""

    def __init__(self, command):
        self.command = command

    async def stream(self, desktop):
        """Feeds `desktop` from the event stream until it ends; returns why, if it never started."""
        heard = False
        proc = await asyncio.create_subprocess_exec(
            self.command, "msg", "--json", "event-stream",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, limit=LINE_MAX, env=niri_env(),
        )
        async for line in proc.stdout:
            heard = True
            try:
                self._event(desktop, json.loads(line))
            except (ValueError, TypeError, KeyError, AttributeError):
                continue
        await proc.wait()
        # A stream that never reported a window never found the compositor.
        return None if heard else f"no niri event stream (NIRI_SOCKET={niri_socket() or 'unset'})"

    def _event(self, desktop, event):
        windows, focused = dict(desktop.windows), desktop.focused
        if "WindowsChanged" in event:
            listed = event["WindowsChanged"]["windows"]
            windows = {w["id"]: w.get("pid") for w in listed}
            focused = next((w["id"] for w in listed if w.get("is_focused")), None)
        elif "WindowOpenedOrChanged" in event:
            window = event["WindowOpenedOrChanged"]["window"]
            windows[window["id"]] = window.get("pid")
            if window.get("is_focused"):
                focused = window["id"]
        elif "WindowClosed" in event:
            windows.pop(event["WindowClosed"]["id"], None)
            if focused == event["WindowClosed"]["id"]:
                focused = None
        elif "WindowFocusChanged" in event:
            focused = event["WindowFocusChanged"]["id"]
        desktop.update(windows, focused)

    async def _action(self, *args):
        proc = await asyncio.create_subprocess_exec(
            self.command, "msg", "action", *args,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL, env=niri_env(),
        )
        await proc.wait()

    async def spawn(self, argv):
        await self._action("spawn", "--", *argv)

    async def focus(self, window):
        await self._action("focus-window", "--id", str(window))


class Desktop:
    """Window ↔ pid map and the focused window, from niri.
    Without a `niri` command there are no windows: a headless hub."""

    def __init__(self, niri, on_change):
        self.niri = niri
        self.on_change = on_change
        self.windows = {}
        self.focused = None
        self.compositor = None
        # Why the last event stream ended, so a stream that never connects is said once.
        self.lost = None

    async def run(self):
        while self.niri:
            self.compositor = Niri(self.niri)
            try:
                failure = await self.compositor.stream(self)
            except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
                failure = f"lost {type(self.compositor).__name__}: {error}"
            if failure:
                self._lost(failure)
            else:
                self.lost = None
            self.compositor = None
            self.windows, self.focused = {}, None
            self.on_change()
            await asyncio.sleep(RETRY)

    def _lost(self, message):
        """Says why the compositor went missing, once per reason rather than every retry."""
        if message != self.lost:
            self.lost = message
            print(f"agent-hub: {message}", file=sys.stderr)

    def update(self, windows, focused):
        # Most events are title changes, which move no pid and no focus.
        if (windows, focused) != (self.windows, self.focused):
            self.windows, self.focused = windows, focused
            self.on_change()

    def window_of(self, pid):
        # No windows (a headless hub) means no ancestor walk, which is a `ps` per step off Linux.
        if not self.windows:
            return None
        return nearest(pid, {p: w for w, p in self.windows.items() if p})

    async def spawn(self, argv):
        """Runs `argv` as the compositor would from a bind, so it gets the session's environment."""
        if self.compositor:
            await self.compositor.spawn(argv)

    async def focus(self, window):
        if self.compositor:
            await self.compositor.focus(window)
