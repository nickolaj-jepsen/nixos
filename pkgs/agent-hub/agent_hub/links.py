"""Other hosts' hubs, piped in over ssh. No server: each hub owns its own sessions,
and a viewer runs `agent-hub attach` on the other end, which bridges stdin and stdout to that
host's socket, passing `subscribe` and nothing else, so a link can change nothing on the far
host. What comes back is untrusted (`clean_row`): a viewer stamps the host itself and builds
every command and URL locally.
"""

import asyncio
import json
import os
import re
import socket
import sys
import threading
import time
from pathlib import Path

from . import protocol
from .common import LINE_MAX, folded, state_dir

# `attach` beats this often, so a dead link shows long before ssh's own keepalives say so.
BEAT = 20
DEAD_AFTER = 60
RETRY_MIN = 5
RETRY_MAX = 60
# A host that doesn't understand us waits for a switch, so it isn't asked often.
RETRY_REFUSED = 300
TEXT_MAX = 500
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
PANE = re.compile(r"%\d{1,6}")
BRIDGE = re.compile(r"[A-Za-z0-9_-]{1,128}")
# C0 and C1 controls, ESC included, which `folded` alone would let through to a terminal or the bar.
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
# What ssh's stderr says → the link's status.
FAILURES = (
    (re.compile(r"permission denied|no supported authentication|host key verification", re.I), "auth failed"),
    (re.compile(r"timed out", re.I), "timeout"),
    (re.compile(r"no hub here", re.I), "no hub"),
)


def text(value, limit=TEXT_MAX):
    """A remote string, safe to show: one line, no control characters, capped."""
    return folded(CONTROL.sub(" ", value))[:limit] if isinstance(value, str) else ""


def whole(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def remote_id(host, sid):
    return f"{host}:{sid}"


def split_id(rid):
    """(host, session id) for a remote row's id, (None, rid) for a local one's."""
    host, sep, sid = rid.partition(":")
    return (host, sid) if sep else (None, rid)


def clean_row(host, row):
    """A row from `host`, as this hub shows it, or None when it can't be. Only what is named here
    survives: pid and window stay on the host they mean something on."""
    if not isinstance(row, dict) or not UUID.fullmatch(str(row.get("id"))) or row.get("state") not in protocol.STATES:
        return None
    tmux, bridge = str(row.get("tmux") or ""), str(row.get("bridge") or "")
    cleaned = {
        "id": remote_id(host, row["id"]),
        "host": host,
        "agent": "pi" if row.get("agent") == "pi" else "claude",
        "name": text(row.get("name"), 120),
        "cwd": text(row.get("cwd")),
        "pid": None,
        "state": row["state"],
        "reason": text(row.get("reason")),
        "since": whole(row.get("since")),
        "doing": text(row.get("doing")),
        "waitingFor": text(row.get("waitingFor")),
        "window": None,
        "turn": whole(row.get("turn")),
    }
    if PANE.fullmatch(tmux):
        cleaned["tmux"] = tmux
    if BRIDGE.fullmatch(bridge):
        cleaned["bridge"] = bridge
    if text(row.get("project"), 200):
        cleaned["project"] = text(row.get("project"), 200)
    return cleaned


class Link:
    """A subscription to one other host's hub, kept up for as long as this hub runs."""

    def __init__(self, host, ssh, config, on_change):
        self.host = host
        self.ssh = ssh
        # Our own ssh config: the login config's `*` would multiplex this over a full login.
        self.config = config
        self.on_change = on_change
        self.rows = []
        self.status = "connecting"
        self.proc = None

    def view(self):
        return {"host": self.host, "status": self.status}

    def _set(self, status, rows=None):
        changed = status != self.status or rows != self.rows
        self.status = status
        self.rows = [] if rows is None else rows
        if changed:
            self.on_change()

    def _take(self, line):
        """Takes one line from the other hub; returns the status it moves the link to, if any."""
        try:
            message = json.loads(line)
        except ValueError:
            return None
        kind = message.get("type") if isinstance(message, dict) else None
        if kind == "error":
            return "needs a switch"
        if kind == "state" and isinstance(message.get("sessions"), list):
            rows = [clean_row(self.host, r) for r in message["sessions"]]
            self._set("up", [r for r in rows if r])
        return None

    async def _session(self):
        """One ssh session, until it ends; returns the status it leaves the link in."""
        self.proc = proc = await asyncio.create_subprocess_exec(
            self.ssh, "-T", "-F", self.config, self.host, "agent-hub", "attach",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, limit=LINE_MAX,
        )
        proc.stdin.write(b'{"op":"subscribe"}\n')
        errors = asyncio.create_task(proc.stderr.read(4096))
        moved = None
        try:
            while moved is None:
                line = await asyncio.wait_for(proc.stdout.readline(), DEAD_AFTER)
                if not line:
                    break
                moved = self._take(line)
        except asyncio.TimeoutError:
            moved = "timeout"
        except (OSError, ValueError):
            pass
        finally:
            if proc.returncode is None:
                proc.kill()
            await proc.wait()
        said = (await errors).decode(errors="replace")
        return moved or next((status for pattern, status in FAILURES if pattern.search(said)), "host down")

    async def run(self):
        wait = RETRY_MIN
        while True:
            try:
                status = await self._session()
            except OSError:
                status = "host down"
            was_up = self.status == "up"
            self._set(status)
            wait = RETRY_MIN if was_up else min(wait * 2, RETRY_MAX)
            await asyncio.sleep(RETRY_REFUSED if status == "needs a switch" else wait)


def attach_socket():
    """The hub's socket from an ssh login, which may have no XDG_RUNTIME_DIR."""
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    candidates = [Path(runtime) / "agent-hub" / "hub.sock", state_dir() / "hub.sock"]
    return next((path for path in candidates if path.exists()), None)


def attach_filter(line):
    """The op a viewer may send: `subscribe`, always for this host's own sessions, so hubs that
    list each other never echo rows around. Anything else is dropped."""
    try:
        message = json.loads(line)
    except ValueError:
        return None
    if isinstance(message, dict) and message.get("op") == "subscribe":
        return {"op": "subscribe", "local": True}
    return None


def attach():
    """Bridges stdin and stdout to this host's hub until either side goes. Only `subscribe` passes."""
    path = attach_socket()
    if path is None:
        sys.exit("agent-hub: no hub here")
    sock = socket.socket(socket.AF_UNIX)
    try:
        sock.connect(str(path))
    except OSError:
        sys.exit("agent-hub: no hub here")
    lock = threading.Lock()
    out = sys.stdout.buffer

    def emit(data):
        with lock:
            out.write(data)
            out.flush()

    def beat():
        while True:
            time.sleep(BEAT)
            emit(b'{"type":"beat"}\n')

    def incoming():
        for line in sys.stdin.buffer:
            message = attach_filter(line)
            if message is not None:
                sock.sendall((json.dumps(message) + "\n").encode())
        # The viewer went: don't leave a subscriber behind.
        os._exit(0)

    threading.Thread(target=beat, daemon=True).start()
    threading.Thread(target=incoming, daemon=True).start()
    try:
        while chunk := sock.recv(65536):
            emit(chunk)
    except (OSError, BrokenPipeError):
        pass
    # The hub went: the viewer retries.
    os._exit(0)
