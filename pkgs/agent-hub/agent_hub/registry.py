"""The session registry Claude Code keeps and pi writes into."""

import asyncio
import ctypes
import json
import os
import sys

from .common import alive

RESCAN_DELAY = 0.05
# Without inotify and pidfds, a rescan this often stands in for both.
POLL_INTERVAL = 1.0
IN_CLOSE_WRITE = 0x08
IN_MOVED_FROM = 0x40
IN_MOVED_TO = 0x80
IN_CREATE = 0x100
IN_DELETE = 0x200


class RegistrySource:
    """Live interactive sessions, from the registry Claude Code keeps and pi writes into.

    `sessions` maps sessionId to its entry; `on_change` fires when that mapping
    changes, including when a process dies and leaves its file behind. Linux
    watches with inotify and pidfds; elsewhere, or with `poll`, it rescans.
    """

    def __init__(self, directory, on_change, poll=False):
        self.directory = directory
        self.on_change = on_change
        self.poll = poll or sys.platform != "linux"
        self.sessions = {}
        self._pidfds = {}
        self._pending = None

    def start(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        if self.poll:
            self._tick()
            return
        libc = ctypes.CDLL(None, use_errno=True)
        fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        mask = IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE
        if fd < 0 or libc.inotify_add_watch(fd, os.fsencode(self.directory), mask) < 0:
            raise OSError(ctypes.get_errno(), f"inotify on {self.directory}")
        asyncio.get_running_loop().add_reader(fd, self._drain, fd)
        self._rescan()

    def _tick(self):
        self._rescan()
        asyncio.get_running_loop().call_later(POLL_INTERVAL, self._tick)

    def _drain(self, fd):
        try:
            while os.read(fd, 65536):
                pass
        except BlockingIOError:
            pass
        self._schedule()

    def _schedule(self):
        # Writers go through a temp file and a rename, so one update is several events.
        if self._pending is None:
            self._pending = asyncio.get_running_loop().call_later(RESCAN_DELAY, self._rescan)

    def _rescan(self):
        self._pending = None
        fronts, jobs = [], {}
        for path in self.directory.glob("*.json"):
            try:
                entry = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if not (isinstance(entry, dict) and entry.get("sessionId") and alive(entry)):
                continue
            if entry.get("kind") == "interactive":
                fronts.append(entry)
            elif entry.get("kind") == "bg" and entry.get("jobId"):
                jobs[entry["jobId"]] = entry
        found, pids = {}, set()
        for entry in fronts:
            pids.add(entry["pid"])
            # Claude Code can park a conversation in a bg job that lives on under its daemon; the
            # front's own entry goes stale, so the job speaks for it and the front keeps the window.
            job = jobs.get(entry.get("parkedJobId"))
            if job:
                pids.add(job["pid"])
                entry = {**job, "pid": entry["pid"]}
            found[str(entry["sessionId"])] = entry
        self._watch_pids(pids)
        if found != self.sessions:
            self.sessions = found
            self.on_change()

    def _watch_pids(self, pids):
        if self.poll:
            return
        loop = asyncio.get_running_loop()
        for pid in set(self._pidfds) - pids:
            fd = self._pidfds.pop(pid)
            loop.remove_reader(fd)
            os.close(fd)
        for pid in pids - set(self._pidfds):
            try:
                fd = os.pidfd_open(pid)
            except OSError:
                continue
            self._pidfds[pid] = fd
            loop.add_reader(fd, self._schedule)
