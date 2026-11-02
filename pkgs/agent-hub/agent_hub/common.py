"""What the daemon and the CLI share: config, the socket, and reading processes."""

import json
import os
import shlex
import socket
import struct
import sys
import time
from pathlib import Path

LINE_MAX = 1 << 22
LABEL_MAX = 200


def state_dir():
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "agent-hub"


def load_config():
    """The daemon's config. Only a desktop names `niri`; without it the hub runs
    headless, for the agents' own TUIs."""
    default = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "agent-hub" / "config.json"
    path = Path(os.environ.get("AGENT_HUB_CONFIG") or default)
    cfg = {"registry": "~/.claude/sessions", "state": str(state_dir() / "state.json")}
    if path.exists():
        cfg.update(json.loads(path.read_text()))
    return cfg


def log_path(cfg):
    """The work log, beside the state file."""
    return Path(cfg["state"]).expanduser().parent / "log.jsonl"


def socket_path():
    """The runtime dir where there is one; macOS has none, so the state dir. Never TMPDIR:
    the agents' wrappers give each session a TMPDIR of its own."""
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    return (Path(runtime) / "agent-hub" if runtime else state_dir()) / "hub.sock"


def now_ms():
    return int(time.time() * 1000)


def proc_stat(pid):
    """The fields of /proc/<pid>/stat after the command name (state first), or None."""
    try:
        return Path(f"/proc/{int(pid)}/stat").read_text().rsplit(")", 1)[1].split()
    except (OSError, ValueError, TypeError, IndexError):
        return None


def ps(pid, field):
    """One `ps` field of a process, for systems without /proc; None when it is gone."""
    # Imported here: only macOS gets this far, and every status-line refresh imports this module.
    import subprocess

    try:
        out = subprocess.run(["ps", "-o", f"{field}=", "-p", str(int(pid))], capture_output=True, text=True, timeout=2,
                             env=dict(os.environ, LC_ALL="C", TZ="UTC"))
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
        return None
    return out.stdout.strip() or None


# pid → its `ps lstart`, which only changes when the pid is reused, so one `ps` per process.
_starts = {}


def alive(entry):
    """Whether the registry entry's process still runs; `procStart` guards against pid reuse.
    It is field 22 of /proc/<pid>/stat on Linux and `ps lstart` elsewhere, as Claude writes it."""
    pid, start = entry.get("pid"), entry.get("procStart")
    if sys.platform == "linux":
        fields = proc_stat(pid)
        if not fields or fields[0] in ("Z", "X"):
            return False
        return start is None or fields[19] == str(start)
    try:
        os.kill(int(pid), 0)
    except PermissionError:
        pass
    except (OSError, ValueError, TypeError):
        _starts.pop(pid, None)
        return False
    if start is None:
        return True
    if pid not in _starts:
        _starts[pid] = ps(pid, "lstart")
    return _starts[pid] == str(start)


def parent_pid(pid):
    if sys.platform == "linux":
        fields = proc_stat(pid)
        return int(fields[1]) if fields else None
    ppid = ps(pid, "ppid")
    return int(ppid) if ppid and ppid.isdigit() else None


def ancestors(pid):
    chain = []
    while isinstance(pid, int) and pid > 1 and len(chain) < 64:
        chain.append(pid)
        pid = parent_pid(pid)
    return chain


def nearest(pid, by_pid):
    """The value `by_pid` holds for `pid` or its closest ancestor, or None."""
    return next((by_pid[p] for p in ancestors(pid) if p in by_pid), None)


def folded(text):
    return " ".join(str(text).split())


def label_line(text):
    """A label as the hub keeps one: a single line, capped."""
    return folded(text)[:LABEL_MAX]


def json_lines(path):
    """Each JSON object in a JSON-lines file, skipping lines that aren't one; OSError propagates."""
    with open(path, encoding="utf-8", errors="replace") as lines:
        for line in lines:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                yield entry


def write_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(text)
    tmp.rename(path)


def resume_argv(agent, session_id, config_dir=None):
    """The agent command that resumes an ended session, run in its cwd: `claude-work` for
    a ~/.claude-work session."""
    if agent == "pi":
        return ["pi", "--session", session_id[:8]]
    wrapper = "claude-work" if config_dir and Path(config_dir).name == ".claude-work" else "claude"
    return [wrapper, "--resume", session_id]


def resume_command(agent, session_id, cwd, config_dir=None):
    return f"cd {shlex.quote(cwd or '~')} && {shlex.join(resume_argv(agent, session_id, config_dir))}"


def hub_message(message):
    """Sends one message to the hub and hangs up; a missing hub is no error."""
    try:
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(2)
            sock.connect(str(socket_path()))
            sock.sendall((json.dumps(message) + "\n").encode())
    except OSError:
        pass


def hub_request(message, timeout=1.0):
    """Sends one message that carries a `request` number and returns the hub's reply to
    it, or None when the hub is down or slow: callers sit in an agent's prompt path."""
    try:
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(timeout)
            sock.connect(str(socket_path()))
            sock.sendall((json.dumps(message) + "\n").encode())
            buf = b""
            while True:
                while b"\n" not in buf:
                    chunk = sock.recv(LINE_MAX)
                    if not chunk:
                        return None
                    buf += chunk
                line, buf = buf.split(b"\n", 1)
                reply = json.loads(line)
                if isinstance(reply, dict) and reply.get("request") == message.get("request"):
                    return reply
    except (KeyError, OSError, ValueError):
        return None


def hub_state(timeout=1.0):
    """The hub's current `state` message, or None when it is down."""
    return hub_request({"op": "subscribe"}, timeout)


def peer_uid(sock):
    """The uid of the process at the other end, or None where the platform can't say;
    the socket's 0700 directory is the guard there."""
    if hasattr(socket, "SO_PEERCRED"):
        _, uid, _ = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        return uid
    if hasattr(socket, "LOCAL_PEERCRED"):
        # struct xucred: a version, then the uid. SOL_LOCAL is 0.
        _, uid = struct.unpack("Ii", sock.getsockopt(0, socket.LOCAL_PEERCRED, 76)[:8])
        return uid
    return None
