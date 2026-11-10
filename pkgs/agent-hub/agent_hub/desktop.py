"""The desktop layer: the compositor's windows and focus, from niri or Hyprland."""

import asyncio
import json
import os
import shlex
import socket
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


def hyprland_dir():
    """The socket directory of a Hyprland that answers, newest first, or None. A crashed one
    leaves its sockets behind, and the hub's unit can outlive the session that named one."""
    try:
        dirs = sorted(
            (path.parent for path in (runtime_dir() / "hypr").glob("*/.socket.sock")),
            key=lambda path: path.stat().st_mtime, reverse=True,
        )
    except OSError:
        return None
    for path in dirs:
        with socket.socket(socket.AF_UNIX) as probe:
            try:
                probe.connect(str(path / ".socket.sock"))
            except OSError:
                continue
        return path
    return None


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


class Hyprland:
    """Hyprland, over its own two sockets. A window's id is its address as a number."""

    def __init__(self, path):
        self.path = path

    async def stream(self, desktop):
        reader, writer = await asyncio.open_unix_connection(str(self.path / ".socket2.sock"), limit=LINE_MAX)
        try:
            await self._list(desktop)
            async for line in reader:
                name, _, data = line.decode(errors="replace").rstrip("\n").partition(">>")
                if name == "activewindowv2":
                    desktop.update(desktop.windows, self._id(data))
                elif name in ("openwindow", "closewindow"):
                    # Neither event carries a pid.
                    await self._list(desktop)
        finally:
            writer.close()

    @staticmethod
    def _id(address):
        try:
            return int(address, 16)
        except (TypeError, ValueError):
            return None

    async def _list(self, desktop):
        clients = json.loads(await self._request("j/clients"))
        active = json.loads(await self._request("j/activewindow"))
        desktop.update({self._id(c["address"]): c.get("pid") for c in clients}, self._id(active.get("address")))

    async def _request(self, message):
        reader, writer = await asyncio.open_unix_connection(str(self.path / ".socket.sock"))
        try:
            writer.write(message.encode())
            await writer.drain()
            return (await reader.read()).decode(errors="replace")
        finally:
            writer.close()

    async def _dispatch(self, lua):
        try:
            await self._request(f"/dispatch {lua}")
        except OSError:
            pass

    async def spawn(self, argv):
        await self._dispatch(f"hl.dsp.exec_cmd({json.dumps(shlex.join(argv), ensure_ascii=False)})")

    async def focus(self, window):
        await self._dispatch(f'hl.dsp.focus({{ window = "address:{window:#x}" }})')


class Desktop:
    """Window ↔ pid map and the focused window, from whichever compositor is running.
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
            # Both sessions share this config, so the choice is made per connection.
            path = hyprland_dir()
            self.compositor = Hyprland(path) if path else Niri(self.niri)
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
