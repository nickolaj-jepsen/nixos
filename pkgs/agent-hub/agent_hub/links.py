"""Other hosts' hubs, piped in over ssh. No server: each hub owns and judges its own sessions,
and a viewer runs `agent-hub attach` on the other end, which bridges stdin and stdout to that
host's socket. What comes back is untrusted (`clean_row`, `clean_recent`): a viewer stamps the
host itself and builds every command and URL locally.
"""

import asyncio
import json
import os
import re
import shlex
import socket
import sys
import threading
import time
from pathlib import Path

from . import protocol
from .common import LINE_MAX, folded, resume_command, state_dir

# `attach` beats this often, so a dead link shows long before ssh's own keepalives say so.
BEAT = 20
DEAD_AFTER = 60
RETRY_MIN = 5
RETRY_MAX = 60
# A host on another protocol waits for a switch, so it isn't asked often.
RETRY_REFUSED = 300
TEXT_MAX = 500
HISTORY_MAX = 3
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


def clean_history(entries):
    entries = entries if isinstance(entries, list) else []
    return [{"at": whole(e.get("at")), "state": text(e.get("state"), 32), "did": text(e.get("did"))}
            for e in entries[-HISTORY_MAX:] if isinstance(e, dict)]


def clean_row(host, row):
    """A row from `host`, as this hub shows it, or None when it can't be. Only what is named here
    survives: pid, window and `reply` stay on the host they mean something on."""
    if not isinstance(row, dict) or not UUID.fullmatch(str(row.get("id"))) or row.get("state") not in protocol.STATES:
        return None
    tmux, bridge = str(row.get("tmux") or ""), str(row.get("bridge") or "")
    cleaned = {
        "id": remote_id(host, row["id"]),
        "host": host,
        "agent": "pi" if row.get("agent") == "pi" else "claude",
        "name": text(row.get("name"), 120),
        "label": text(row.get("label"), 120),
        "cwd": text(row.get("cwd")),
        "pid": None,
        "state": row["state"],
        "reason": text(row.get("reason")),
        "since": whole(row.get("since")),
        "doing": text(row.get("doing")),
        "summary": text(row.get("summary")),
        "waitingFor": text(row.get("waitingFor")),
        "ask": text(row.get("ask")),
        "reply": "",
        "window": None,
        "history": clean_history(row.get("history")),
        "turn": whole(row.get("turn")),
    }
    if PANE.fullmatch(tmux):
        cleaned["tmux"] = tmux
    if BRIDGE.fullmatch(bridge):
        cleaned["bridge"] = bridge
    return cleaned


def clean_recent(host, item):
    """An ended session from `host`. Its `resume` is ignored and built here, run over ssh."""
    if not isinstance(item, dict) or not UUID.fullmatch(str(item.get("id"))):
        return None
    sid, agent, cwd = item["id"], "pi" if item.get("agent") == "pi" else "claude", text(item.get("cwd"))
    return {
        "id": remote_id(host, sid),
        "host": host,
        "agent": agent,
        "label": text(item.get("label"), 120),
        "summary": text(item.get("summary")),
        "cwd": cwd,
        "endedAt": whole(item.get("endedAt")),
        "resume": f"ssh -t {shlex.quote(host)} {shlex.quote(resume_command(agent, sid, cwd))}",
        "history": clean_history(item.get("history")),
    }


class Link:
    """A subscription to one other host's hub, kept up for as long as this hub runs."""

    def __init__(self, host, ssh, config, on_change):
        self.host = host
        self.ssh = ssh
        # Our own ssh config: the login config's `*` would multiplex this over a full login.
        self.config = config
        self.on_change = on_change
        self.rows = []
        self.recent = []
        self.status = "connecting"
        self.proc = None

    def view(self):
        return {"host": self.host, "status": self.status}

    def send(self, message):
        """Sends an op to the other hub; `attach` drops what its key doesn't allow."""
        if self.proc is not None and self.proc.stdin is not None and self.status == "up":
            self.proc.stdin.write((json.dumps(message) + "\n").encode())

    def _set(self, status, rows=None, recent=None):
        changed = status != self.status or rows != self.rows or recent != self.recent
        self.status = status
        self.rows = [] if rows is None else rows
        self.recent = [] if recent is None else recent
        if changed:
            self.on_change()

    def _take(self, line):
        """Takes one line from the other hub; returns the status it moves the link to, if any."""
        try:
            message = json.loads(line)
        except ValueError:
            return None
        kind = message.get("type") if isinstance(message, dict) else None
        if kind == "refused":
            return "needs a switch"
        if kind == "state":
            rows = [clean_row(self.host, r) for r in message.get("sessions") or [] if isinstance(message.get("sessions"), list)]
            recent = [clean_recent(self.host, r) for r in message.get("recent") or [] if isinstance(message.get("recent"), list)]
            self._set("up", [r for r in rows if r], [r for r in recent if r])
        return None

    async def _session(self):
        """One ssh session, until it ends; returns the status it leaves the link in."""
        self.proc = proc = await asyncio.create_subprocess_exec(
            self.ssh, "-T", "-F", self.config, self.host, "agent-hub", "attach",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, limit=LINE_MAX,
        )
        proc.stdin.write((json.dumps({"op": "subscribe", "version": protocol.VERSION}) + "\n").encode())
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


def attach_filter(line, control):
    """The op a viewer may send, rebuilt from its allowed fields, or None. A subscribe is always
    for this host's own sessions, so hubs that list each other never echo rows around."""
    try:
        message = json.loads(line)
    except ValueError:
        return None
    if not isinstance(message, dict):
        return None
    op = message.get("op")
    if op == "subscribe":
        version = message.get("version")
        return {"op": op, "local": True, **({"version": version} if isinstance(version, int) else {})}
    if op == "dismiss" and control and isinstance(message.get("session"), str):
        turn = message.get("turn")
        return {"op": op, "session": message["session"], **({"turn": turn} if isinstance(turn, int) else {})}
    return None


def attach(control=False):
    """Bridges stdin and stdout to this host's hub until either side goes. Only `subscribe` passes
    by default; `control` adds dismissing, for a key that may."""
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
            message = attach_filter(line, control)
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
