"""What the daemon and the CLI share: config, the socket, and reading processes."""

import json
import os
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
    headless, to serve viewers."""
    default = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "agent-hub" / "config.json"
    path = Path(os.environ.get("AGENT_HUB_CONFIG") or default)
    cfg = {"registry": "~/.claude/sessions"}
    if path.exists():
        cfg.update(json.loads(path.read_text()))
    return cfg


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


def hub_message(message):
    """Sends one message to the hub and hangs up; a missing hub is no error."""
    try:
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(2)
            sock.connect(str(socket_path()))
            sock.sendall((json.dumps(message) + "\n").encode())
    except OSError:
        pass


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


def hidden_by_env(pid):
    """Whether the process was started with `AGENT_HUB_HIDDEN=1`, from /proc; False where there is none."""
    try:
        environ = Path(f"/proc/{int(pid)}/environ").read_bytes()
    except (OSError, ValueError, TypeError):
        return False
    return b"AGENT_HUB_HIDDEN=1" in environ.split(b"\0")
