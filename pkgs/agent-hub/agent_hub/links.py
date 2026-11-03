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
from .common import BLOCK_MAX, LINE_MAX, folded, resume_command, shown_block, state_dir

# `attach` beats this often, so a dead link shows long before ssh's own keepalives say so.
BEAT = 20
DEAD_AFTER = 60
RETRY_MIN = 5
RETRY_MAX = 60
# A host on another protocol waits for a switch, so it isn't asked often.
RETRY_REFUSED = 300
TEXT_MAX = 500
HISTORY_MAX = 3
PEERS_MAX = 5
JOBS_MAX = 5
TRAIL_MAX = 12
# Long enough for the git and gh of the other host, short enough that a menu isn't left open on it.
CALL_TIMEOUT = 5
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


def clean_list(values, limit):
    return [text(value, 120) for value in values[:limit] if isinstance(value, str)] if isinstance(values, list) else []


def clean_counts(value):
    value = value if isinstance(value, dict) else {}
    counts = {key: whole(value.get(key)) for key in ("edits", "commands", "failed")}
    return counts if any(counts.values()) else None


def clean_trail(steps):
    steps = steps if isinstance(steps, list) else []
    return [{"at": whole(step.get("at")), "text": text(step.get("text"), 200)} for step in steps[-TRAIL_MAX:] if isinstance(step, dict)]


def clean_permission(value):
    """A held prompt from another host: text only, and whatever had to be cut can't be allowed."""
    if not isinstance(value, dict) or not whole(value.get("id")):
        return None
    body, fits = shown_block(value.get("body"), BLOCK_MAX)
    return {
        "id": value["id"],
        "tool": text(value.get("tool"), 120),
        "about": text(value.get("about"), 200),
        "kind": value["kind"] if value.get("kind") in ("command", "diff") else "text",
        "body": body,
        "complete": value.get("complete") is True and fits,
    }


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
        "reply": text(row.get("reply")),
        "window": None,
        "history": clean_history(row.get("history")),
        "turn": whole(row.get("turn")),
    }
    if PANE.fullmatch(tmux):
        cleaned["tmux"] = tmux
    if BRIDGE.fullmatch(bridge):
        cleaned["bridge"] = bridge
    details = {
        "prompt": text(row.get("prompt")),
        "said": shown_block(row.get("said"), BLOCK_MAX)[0],
        "askKind": text(row.get("askKind"), 20),
        "permission": clean_permission(row.get("permission")),
        "branch": text(row.get("branch"), 200),
        "changed": whole(row.get("changed")),
        "peers": clean_list(row.get("peers"), PEERS_MAX),
        "activity": whole(row.get("activity")),
        "jobs": clean_list(row.get("jobs"), JOBS_MAX),
        "now": text(row.get("now"), 120),
        "nowAt": whole(row.get("nowAt")),
        "counts": clean_counts(row.get("counts")),
        "trail": clean_trail(row.get("trail")),
    }
    cleaned.update({key: value for key, value in details.items() if value})
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
        # Requests out to the other hub, request → the future its reply lands on.
        self.calls = {}
        self.next_call = 0

    def view(self):
        return {"host": self.host, "status": self.status}

    def send(self, message):
        """Sends an op to the other hub; `attach` drops what its key doesn't allow."""
        if self.proc is not None and self.proc.stdin is not None and self.status == "up":
            self.proc.stdin.write((json.dumps(message) + "\n").encode())

    async def call(self, message):
        """Sends an op that is answered, and returns the `reply`, or None when none comes in time."""
        self.next_call += 1
        request = self.next_call
        future = asyncio.get_running_loop().create_future()
        self.calls[request] = future
        self.send({**message, "request": request})
        try:
            return await asyncio.wait_for(future, CALL_TIMEOUT)
        except asyncio.TimeoutError:
            return None
        finally:
            self.calls.pop(request, None)

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
        elif kind == "reply":
            future = self.calls.get(message.get("request"))
            if future is not None and not future.done():
                future.set_result(message)
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
    if op in ("dismiss", "undismiss") and control and isinstance(message.get("session"), str):
        turn = message.get("turn")
        return {"op": op, "session": message["session"], **({"turn": turn} if isinstance(turn, int) else {})}
    if op == "answer" and control and isinstance(message.get("session"), str) and whole(message.get("ask")) \
            and isinstance(message.get("allow"), bool):
        return {"op": op, "session": message["session"], "ask": message["ask"], "allow": message["allow"]}
    if op == "git-facts" and control and isinstance(message.get("session"), str) and isinstance(message.get("request"), int):
        return {"op": op, "session": message["session"], "request": message["request"]}
    return None


def attach(control=False):
    """Bridges stdin and stdout to this host's hub until either side goes. Only `subscribe` passes
    by default; `control` adds dismissing and undoing it, answering a prompt an agent there has
    already put, and asking what git says of a session, for a key that may."""
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
