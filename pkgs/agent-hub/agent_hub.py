"""Desktop hub for live coding-agent sessions (pi, Claude Code).

`agent-hub daemon` serves line-delimited JSON on $XDG_RUNTIME_DIR/agent-hub/hub.sock:

- `{"op": "subscribe"}`: the bar. Gets a `state` message now and on every change.
- `{"op": "focus", "session"}`: focuses that session's window.
- `{"op": "focus-next"}`: focuses the first session that wants you, or the one
  after it when its window already has focus.
- `{"op": "dismiss", "session"}`: a finished session goes idle until its next turn.
- `{"op": "waiting", "session": {"id"}, "text"}`: a one-line label for the dialog
  a Claude Code session is waiting on, from `agent-hub hook`.
- `{"op": "settled", "session": {"id"}, "transcript", "configDir"}`: a Claude Code
  turn ended, from `agent-hub hook`; `configDir` is the session's CLAUDE_CONFIG_DIR.
- `{"op": "demo", "sessions": [registry entries]}`: fake sessions shown while the
  connection lasts, for `agent-hub demo`.

A session is `asking` while its registry entry says `status: "waiting"`; Claude
Code writes that itself, and pi's claude-peers extension does for its dialogs.
A finished turn stays `needs-reply`, `failed` or `done` until the next one starts
or it is dismissed. pi writes how its turn ended into the registry (`turnState`,
`ask`); a Claude Code turn is read from its transcript, and put to `claude -p`
under the session's own profile when its words alone don't settle it.
"""

import argparse
import asyncio
import ctypes
import json
import os
import re
import socket
import struct
import sys
import time
from pathlib import Path

LINE_MAX = 1 << 22
LABEL_MAX = 200
RESCAN_DELAY = 0.05
RETRY = 2.0
# A dialog answered within this long never toasts, and Claude's hook has time to label it.
TOAST_GRACE_MS = 1000
STATE_ORDER = {"asking": 0, "needs-reply": 1, "failed": 2, "done": 3, "working": 4, "idle": 5}
ATTENTION = ("asking", "needs-reply", "failed", "done")
# How a turn ended (pi's `turnState`, or the classifier's) → the state it leaves the session in.
FINISHED = {"blocked": "needs-reply", "failed": "failed", "done": "done"}
SUMMARY_MAX = 120
# A turn this short that ran no tools is read at a glance, so the model is not asked about it.
WORTH_ASKING_CHARS = 800
TURN_CHARS = 4000
CLASSIFY_TIMEOUT = 60
CLASSIFY_ARGS = [
    "-p", "--model", "haiku", "--no-session-persistence", "--strict-mcp-config", "--tools", "",
    "--disable-slash-commands", "--settings", json.dumps({"disableAllHooks": True}),
]
CLASSIFY_SYSTEM = """You read the last turn of a coding agent's session for the person working in it.
Answer with exactly these three lines, in this order, and nothing else:
state: done, blocked, failed or waiting
ask: what the turn needs from the person, or empty
summary: one sentence of at most 20 words about what the turn did

- done: the turn finished what was asked. blocked: it waits on a decision or an
  answer from the person; a turn with an ask is blocked. failed: it gave up, or says
  the work does not work yet. waiting: it ended only to wait for its own background
  jobs, and carries on by itself when they report back.
- ask is a request, not a summary: "keep the old fixture?", not "asked about the fixture".
- No quotes, no preamble, no other lines."""
TASK_ID = re.compile(r"<task-id>([^<]+)</task-id>")
CODE_BLOCK = re.compile(r"```.*?```", re.S)
MARKDOWN = re.compile(r"[*`#>]+")
# Words of a turn that ended to wait for its own jobs; a server it left running for you says none of them.
WAITS = re.compile(r"\b(wait(ing)? (for|on|until)|(i'll|i will) (be notified|check back)|once (it|they)|when (it|they) (finish|complete|report))", re.I)

IN_CLOSE_WRITE = 0x08
IN_MOVED_FROM = 0x40
IN_MOVED_TO = 0x80
IN_CREATE = 0x100
IN_DELETE = 0x200


def load_config():
    default = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "agent-hub" / "config.json"
    path = Path(os.environ.get("AGENT_HUB_CONFIG") or default)
    state = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "agent-hub" / "state.json"
    cfg = {"registry": "~/.claude/sessions", "niri": "niri", "state": str(state)}
    if path.exists():
        cfg.update(json.loads(path.read_text()))
    return cfg


def socket_path():
    return Path(os.environ["XDG_RUNTIME_DIR"]) / "agent-hub" / "hub.sock"


def now_ms():
    return int(time.time() * 1000)


def proc_stat(pid):
    """The fields of /proc/<pid>/stat after the command name (state first), or None."""
    try:
        return Path(f"/proc/{int(pid)}/stat").read_text().rsplit(")", 1)[1].split()
    except (OSError, ValueError, TypeError, IndexError):
        return None


def alive(entry):
    """Whether the registry entry's process still runs; `procStart` guards against pid reuse."""
    fields = proc_stat(entry.get("pid"))
    if not fields or fields[0] in ("Z", "X"):
        return False
    start = entry.get("procStart")
    return start is None or fields[19] == str(start)


def ancestors(pid):
    chain = []
    while isinstance(pid, int) and pid > 1 and len(chain) < 64:
        chain.append(pid)
        fields = proc_stat(pid)
        pid = int(fields[1]) if fields else None
    return chain


def nearest(pid, by_pid):
    """The value `by_pid` holds for `pid` or its closest ancestor, or None."""
    return next((by_pid[p] for p in ancestors(pid) if p in by_pid), None)


def peer_uid(sock):
    _, uid, _ = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
    return uid


def folded(text):
    return " ".join(str(text).split())


def since(entry):
    """When the entry's status last changed, which marks the turn a dismissal is for."""
    return entry.get("statusUpdatedAt") or entry.get("startedAt") or 0


def blocks(entry):
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []


def prompt_text(entry):
    """What the person typed, when a transcript entry is a prompt that starts a turn."""
    if entry.get("type") != "user" or entry.get("isMeta") or "toolUseResult" in entry:
        return None
    parts = [b.get("text") or "" for b in blocks(entry) if b.get("type") == "text"]
    # A background job reporting back resumes the turn; it doesn't start one.
    if not parts or parts[0].lstrip().startswith("<task-notification>"):
        return None
    return "\n".join(parts)


def read_turn(path):
    """How the last turn of a Claude Code transcript ended, by its words alone, or None
    when it can't be read. `pending` counts background jobs that never reported back,
    and `jobs` those of them the turn says it waits on: a dev server it left running
    is pending, not waited on. `worth` says whether the turn is worth a model's reading."""
    started, finished = set(), set()
    prompt, tools, text = "", 0, []
    try:
        with open(path, encoding="utf-8", errors="replace") as lines:
            for line in lines:
                if "<task-notification>" in line:
                    finished.update(TASK_ID.findall(line))
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict) or entry.get("isSidechain"):
                    continue
                result = entry.get("toolUseResult")
                if isinstance(result, dict):
                    job = result.get("backgroundTaskId") or (result.get("agentId") if result.get("isAsync") else None)
                    if job:
                        started.add(str(job))
                said = prompt_text(entry)
                if said is not None:
                    prompt, tools, text = said, 0, []
                elif entry.get("type") == "assistant":
                    for block in blocks(entry):
                        if block.get("type") == "tool_use":
                            tools, text = tools + 1, []
                        elif block.get("type") == "text":
                            text.append(block.get("text") or "")
    except OSError:
        return None
    final = CODE_BLOCK.sub("", "\n".join(text)).strip()
    paragraphs = [folded(MARKDOWN.sub("", p)) for p in re.split(r"\n\s*\n", final)]
    paragraphs = [p for p in paragraphs if p]
    # The ask is whatever the turn's last words put to you.
    sentences = re.split(r"(?<=[.?!])\s+", " ".join(paragraphs[-2:]))
    asks = [s for s in sentences if s.endswith("?")]
    first = re.split(r"(?<=[.?!])\s+", paragraphs[0])[0] if paragraphs else ""
    return {
        "state": "blocked" if asks else "done",
        "ask": asks[-1][:LABEL_MAX] if asks else "",
        "summary": first[:SUMMARY_MAX],
        "pending": len(started - finished),
        "jobs": len(started - finished) if WAITS.search(final) else 0,
        "worth": tools > 0 or len(final) >= WORTH_ASKING_CHARS,
        "prompt": folded(prompt)[:500],
        "text": final[-TURN_CHARS:],
    }


def classify_prompt(turn):
    parts = [f"The person asked:\n{turn['prompt']}"] if turn["prompt"] else []
    if turn["pending"]:
        parts.append(f"Background jobs started in the session that have not reported back: {turn['pending']}")
    parts.append(f"The assistant's turn ended with:\n{turn['text']}")
    return "\n\n".join(parts)


def parse_classification(text):
    """The classifier's answer as `{"state", "ask", "summary"}`, or None when it didn't keep to the form."""
    fields = {}
    for line in text.splitlines():
        key, sep, value = line.partition(":")
        key = MARKDOWN.sub("", key).strip().lower()
        if sep and key in ("state", "ask", "summary"):
            fields[key] = folded(MARKDOWN.sub("", value)).strip("\"' ")
    state = fields.get("state", "").lower()
    if state not in ("done", "blocked", "failed", "waiting"):
        return None
    ask = "" if fields.get("ask", "").lower() in ("", "empty", "none", "-") else fields["ask"]
    return {
        "state": "blocked" if ask else state,
        "ask": ask[:LABEL_MAX],
        "summary": fields.get("summary", "")[:SUMMARY_MAX],
    }


class RegistrySource:
    """Live interactive sessions, from the registry Claude Code keeps and pi writes into.

    `sessions` maps sessionId to its entry; `on_change` fires when that mapping
    changes, including when a process dies and leaves its file behind.
    """

    def __init__(self, directory, on_change):
        self.directory = directory
        self.on_change = on_change
        self.sessions = {}
        self._pidfds = {}
        self._pending = None

    def start(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        libc = ctypes.CDLL(None, use_errno=True)
        fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        mask = IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE
        if fd < 0 or libc.inotify_add_watch(fd, os.fsencode(self.directory), mask) < 0:
            raise OSError(ctypes.get_errno(), f"inotify on {self.directory}")
        asyncio.get_running_loop().add_reader(fd, self._drain, fd)
        self._rescan()

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


class Niri:
    """Window ↔ pid map and the focused window, from `niri msg --json event-stream`."""

    def __init__(self, command, on_change):
        self.command = command
        self.on_change = on_change
        self.windows = {}
        self.focused = None

    async def run(self):
        while True:
            try:
                proc = await asyncio.create_subprocess_exec(
                    self.command, "msg", "--json", "event-stream",
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, limit=LINE_MAX,
                )
                async for line in proc.stdout:
                    try:
                        self._event(json.loads(line))
                    except (ValueError, TypeError, KeyError, AttributeError):
                        continue
                await proc.wait()
            except OSError:
                pass
            self.windows, self.focused = {}, None
            self.on_change()
            await asyncio.sleep(RETRY)

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
        return nearest(pid, {p: w for w, p in self.windows.items() if p})

    async def focus(self, window):
        proc = await asyncio.create_subprocess_exec(
            self.command, "msg", "action", "focus-window", "--id", str(window),
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()


class Conn:
    def __init__(self, writer):
        self.writer = writer
        self.uid = peer_uid(writer.get_extra_info("socket"))
        self.subscriber = False
        self.demo = {}

    def send(self, payload):
        if not self.writer.is_closing():
            self.writer.write((json.dumps(payload) + "\n").encode())


class Toasts:
    """Desktop notifications for a session that wants you in a window you are not
    looking at; each closes once the session no longer wants you or you look at it.

    Every toast is shown once: looking away again does not bring it back.
    """

    SHOWN_MAX = 512

    def __init__(self, cfg, on_click):
        self.notify_send = cfg.get("notifySend")
        self.busctl = cfg.get("busctl")
        self.on_click = on_click
        self.open = {}
        self.shown = {}

    def sync(self, sessions, focused, now):
        if not self.notify_send:
            return
        wanted = {}
        for row in sessions:
            name = row["name"] or os.path.basename(row["cwd"]) or row["agent"]
            if focused is not None and row["window"] == focused:
                continue
            state = row["state"]
            if state == "asking" and now - row["since"] < TOAST_GRACE_MS:
                continue
            title = {"asking": f"{name} needs you", "needs-reply": f"{name} asks", "failed": f"Failed: {name}",
                     "done": f"Done: {name}"}.get(state)
            if title:
                body = row["waitingFor"] or row["ask"] or row["summary"] or row["cwd"]
                wanted[row["id"]] = (f"{state}:{row['since']}", title, body)
        for sid, toast in list(self.open.items()):
            if wanted.get(sid, (None,))[0] != toast["key"]:
                self._close(self.open.pop(sid))
        for sid, (key, summary, body) in wanted.items():
            if sid in self.open or key in self.shown:
                continue
            self.shown[key] = True
            while len(self.shown) > self.SHOWN_MAX:
                del self.shown[next(iter(self.shown))]
            toast = {"key": key, "id": None, "closed": False}
            self.open[sid] = toast
            toast["task"] = asyncio.create_task(self._show(sid, toast, summary, body))

    async def _show(self, sid, toast, summary, body):
        try:
            proc = await asyncio.create_subprocess_exec(
                self.notify_send, "--app-name=agent-hub", "--print-id", "--wait", "--action=default=Open", summary, body,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            toast["id"] = int((await proc.stdout.readline()).strip() or 0) or None
            if toast["closed"]:
                await self._dismiss(toast)
            async for line in proc.stdout:
                if line.strip() == b"default" and not toast["closed"]:
                    await self.on_click(sid)
            await proc.wait()
        except (OSError, ValueError):
            pass
        finally:
            if self.open.get(sid) is toast:
                del self.open[sid]

    def _close(self, toast):
        toast["closed"] = True
        if toast["id"] is not None:
            asyncio.create_task(self._dismiss(toast))

    async def _dismiss(self, toast):
        if not self.busctl or toast["id"] is None:
            return
        proc = await asyncio.create_subprocess_exec(
            self.busctl, "--user", "call", "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications", "CloseNotification", "u", str(toast["id"]),
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()


class Hub:
    def __init__(self, cfg):
        self.source = RegistrySource(Path(cfg["registry"]).expanduser(), self.changed)
        self.niri = Niri(cfg["niri"], self.changed)
        self.toasts = Toasts(cfg, self._focus)
        self.claude = cfg.get("claude")
        self.state_file = Path(cfg["state"]).expanduser()
        self.conns = set()
        self.status = {}
        # Session id → the hook's label for the dialog it waits on, until its status moves on.
        self.labels = {}
        saved = self._load()
        # Session id → how its last Claude Code turn ended, until the next one starts.
        self.outcomes = saved.get("outcomes") or {}
        # Session id → the `since` of the finished turn you dismissed.
        self.dismissed = saved.get("dismissed") or {}
        self._last = None
        self._toast_timer = None
        self._tasks = set()

    def _load(self):
        try:
            saved = json.loads(self.state_file.read_text())
        except (OSError, ValueError):
            return {}
        return saved if isinstance(saved, dict) else {}

    def _save(self):
        try:
            self.state_file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.state_file.with_suffix(".tmp")
            tmp.write_text(json.dumps({"outcomes": self.outcomes, "dismissed": self.dismissed}))
            tmp.rename(self.state_file)
        except OSError as error:
            print(f"agent-hub: can't save {self.state_file}: {error}", file=sys.stderr)

    async def run(self):
        path = socket_path()
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.unlink(missing_ok=True)
        server = await asyncio.start_unix_server(self._serve, path=str(path), limit=LINE_MAX)
        path.chmod(0o600)
        self.source.start()
        niri = asyncio.create_task(self.niri.run())
        async with server:
            await asyncio.gather(server.serve_forever(), niri)

    def changed(self):
        sessions = self.source.sessions
        saved = (dict(self.outcomes), dict(self.dismissed))
        for sid, entry in sessions.items():
            status, before = entry.get("status"), self.status.get(sid)
            # The hook can beat the registry to a dialog, so only a move away from it drops a label.
            if status != before and status != "waiting":
                self.labels.pop(sid, None)
            # Only a new turn ends the last one: the Stop hook can land before the registry goes idle.
            if status == "busy" and before != "busy":
                self.outcomes.pop(sid, None)
            self.status[sid] = status
        self.status = {sid: s for sid, s in self.status.items() if sid in sessions}
        self.labels = {sid: text for sid, text in self.labels.items() if sid in sessions}
        self.outcomes = {sid: o for sid, o in self.outcomes.items() if sid in sessions}
        self.dismissed = {sid: t for sid, t in self.dismissed.items() if sid in sessions and since(sessions[sid]) == t}
        if (self.outcomes, self.dismissed) != saved:
            self._save()
        self.publish()

    def state(self):
        entries = dict(self.source.sessions)
        for conn in self.conns:
            entries.update(conn.demo)
        rows = []
        for sid, entry in entries.items():
            status = entry.get("status")
            turn = self.outcomes.get(sid) or ({"state": entry["turnState"], "ask": entry.get("ask") or ""} if entry.get("turnState") else None)
            doing = entry.get("doing") or ""
            if status == "waiting":
                state = "asking"
            elif status == "busy":
                state = "working"
            elif turn and turn.get("jobs"):
                state = "working"
                doing = f"waiting on {turn['jobs']} background job" + ("s" if turn["jobs"] > 1 else "")
            elif turn and self.dismissed.get(sid) != since(entry):
                state = FINISHED.get(turn["state"], "done")
            else:
                state = "idle"
            rows.append({
                "id": sid,
                "agent": "pi" if entry.get("entrypoint") == "pi" else "claude",
                "name": entry.get("name") or "",
                "cwd": entry.get("cwd") or "",
                "pid": entry.get("pid"),
                "doing": doing,
                "summary": entry.get("summary") or (turn or {}).get("summary") or "",
                "waitingFor": (self.labels.get(sid) or entry.get("waitingFor") or "") if state == "asking" else "",
                "ask": turn["ask"] if state == "needs-reply" else "",
                "since": since(entry),
                "state": state,
                "window": self.niri.window_of(entry.get("pid")),
            })
        # The one order: the bar lists it, and focus-next walks it.
        # What wants you, longest-waiting first; the rest, latest first.
        rows.sort(key=lambda r: (STATE_ORDER[r["state"]], r["since"] if r["state"] in ATTENTION else -r["since"]))
        return {"type": "state", "sessions": rows}

    def publish(self, force_to=None):
        state = self.state()
        now = now_ms()
        self.toasts.sync(state["sessions"], self.niri.focused, now)
        self._schedule_toasts(state["sessions"], now)
        if state != self._last:
            self._last = state
            for conn in self.conns:
                if conn.subscriber and conn is not force_to:
                    conn.send(state)
        if force_to is not None:
            force_to.send(state)

    def _schedule_toasts(self, sessions, now):
        """Publishes again when the next dialog still in its grace period comes out of it."""
        due = [r["since"] + TOAST_GRACE_MS - now for r in sessions if r["state"] == "asking" and now - r["since"] < TOAST_GRACE_MS]
        if self._toast_timer is not None:
            self._toast_timer.cancel()
            self._toast_timer = None
        if due:
            self._toast_timer = asyncio.get_running_loop().call_later(min(due) / 1000, self.publish)

    async def _settle(self, sid, transcript, config_dir):
        turn = await asyncio.to_thread(read_turn, transcript)
        if turn is None:
            return
        outcome = {key: turn[key] for key in ("state", "ask", "summary", "jobs")}
        self.outcomes[sid] = outcome
        self._save()
        self.publish()
        # Pending jobs always go to the model: only it can tell a turn waiting on them from a server left running.
        if not self.claude or not (turn["pending"] or (turn["worth"] and turn["state"] == "done")):
            return
        answer = await self._classify(turn, config_dir)
        # A turn that started meanwhile, or a newer Stop, has the last word.
        if answer is None or self.outcomes.get(sid) is not outcome:
            return
        waiting = answer["state"] == "waiting"
        self.outcomes[sid] = {
            "state": "done" if waiting else answer["state"],
            "ask": answer["ask"],
            "summary": answer["summary"] or turn["summary"],
            "jobs": max(turn["pending"], 1) if waiting else 0,
        }
        self._save()
        self.publish()

    async def _classify(self, turn, config_dir):
        """Asks `claude -p` how the turn ended, as the session's own profile."""
        env = dict(os.environ)
        # Unset means the default profile; naming ~/.claude instead would move its config file.
        if config_dir:
            env["CLAUDE_CONFIG_DIR"] = config_dir
        proc = None
        try:
            proc = await asyncio.create_subprocess_exec(
                self.claude, *CLASSIFY_ARGS, "--system-prompt", CLASSIFY_SYSTEM,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
                env=env, cwd=str(socket_path().parent),
            )
            out, _ = await asyncio.wait_for(proc.communicate(classify_prompt(turn).encode()), CLASSIFY_TIMEOUT)
        except (OSError, asyncio.TimeoutError):
            if proc and proc.returncode is None:
                proc.kill()
            return None
        return parse_classification(out.decode(errors="replace")) if proc.returncode == 0 else None

    def _spawn(self, coro):
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _focus(self, sid):
        row = next((r for r in self._last["sessions"] if r["id"] == sid), None) if self._last else None
        if row and row["window"] is not None:
            await self.niri.focus(row["window"])

    async def _focus_next(self):
        if not self._last:
            return
        targets = [r for r in self._last["sessions"] if r["state"] in ATTENTION and r["window"] is not None]
        if not targets:
            return
        at = next((i for i, r in enumerate(targets) if r["window"] == self.niri.focused), None)
        await self.niri.focus(targets[0 if at is None else (at + 1) % len(targets)]["window"])

    async def _serve(self, reader, writer):
        try:
            conn = Conn(writer)
        except OSError:
            writer.close()
            return
        if conn.uid != os.getuid():
            writer.close()
            return
        self.conns.add(conn)
        try:
            async for line in reader:
                try:
                    message = json.loads(line)
                    if not isinstance(message, dict):
                        raise ValueError("not an object")
                    await self._dispatch(conn, message)
                except ValueError as error:
                    conn.send({"type": "error", "error": str(error)})
        except (ConnectionError, asyncio.LimitOverrunError, ValueError):
            pass
        finally:
            self.conns.discard(conn)
            writer.close()
            if conn.demo:
                self.publish()

    async def _dispatch(self, conn, message):
        op = message.get("op")
        if op == "subscribe":
            conn.subscriber = True
            self.publish(force_to=conn)
        elif op == "focus":
            await self._focus(message.get("session"))
        elif op == "focus-next":
            await self._focus_next()
        elif op == "waiting":
            sid = str((message.get("session") or {}).get("id") or "")
            if sid:
                self.labels[sid] = folded(message.get("text") or "")[:LABEL_MAX]
                self.publish()
        elif op == "settled":
            sid = str((message.get("session") or {}).get("id") or "")
            transcript = message.get("transcript")
            if sid and isinstance(transcript, str):
                self._spawn(self._settle(sid, transcript, message.get("configDir") or None))
        elif op == "dismiss":
            sid = str(message.get("session") or "")
            row = next((r for r in self._last["sessions"] if r["id"] == sid), None) if self._last else None
            if row and row["state"] in ("needs-reply", "failed", "done"):
                self.dismissed[sid] = row["since"]
                self._save()
                self.publish()
        elif op == "demo":
            entries = message.get("sessions") or []
            conn.demo = {str(e["sessionId"]): e for e in entries if isinstance(e, dict) and e.get("sessionId")}
            self.publish()
        else:
            raise ValueError(f"unknown op {op!r}")


def shown_path(path, cwd):
    path = str(path)
    if cwd and path.startswith(cwd.rstrip("/") + "/"):
        return path[len(cwd.rstrip("/")) + 1:]
    home = str(Path.home())
    return "~" + path[len(home):] if path.startswith(home + "/") else path


def claude_label(tool, args, cwd):
    """One line naming what a Claude Code tool call would do."""
    tool = str(tool or "")
    args = args if isinstance(args, dict) else {}
    if tool.startswith("mcp__"):
        server, _, name = tool[len("mcp__"):].partition("__")
        return f"{server} · {name}"
    if tool == "Bash":
        value = args.get("command")
    elif tool in ("Edit", "MultiEdit", "Write", "NotebookEdit"):
        target = args.get("file_path") or args.get("notebook_path")
        value = shown_path(target, cwd) if target else None
    elif tool == "WebFetch":
        value = args.get("url")
    elif tool == "WebSearch":
        value = args.get("query")
    else:
        value = None
    return folded(f"{tool}: {value}")[:LABEL_MAX] if value else tool


def hub_message(message):
    """Sends one message to the hub and hangs up; a missing hub is no error."""
    try:
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(2)
            sock.connect(str(socket_path()))
            sock.sendall((json.dumps(message) + "\n").encode())
    except OSError:
        pass


def cmd_hook(_args):
    """A Claude Code hook that prints nothing, so Claude's own handling is unchanged:
    Stop hands the hub the transcript of the turn that ended, PermissionRequest labels
    the dialog for the bar."""
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return
    if event.get("hook_event_name") == "Stop":
        hub_message({
            "op": "settled",
            "session": {"id": event.get("session_id")},
            "transcript": event.get("transcript_path"),
            "configDir": os.environ.get("CLAUDE_CONFIG_DIR"),
        })
        return
    hub_message({
        "op": "waiting",
        "session": {"id": event.get("session_id")},
        "text": claude_label(event.get("tool_name"), event.get("tool_input"), event.get("cwd")),
    })


def cmd_focus_next(_args):
    hub_message({"op": "focus-next"})


def demo_sessions():
    """Registry-shaped fake sessions, one or more per state."""
    t = now_ms()
    entries = [
        ("demo-bash", "cli", "waiting", "nixos-d0", {"waitingFor": "Bash: cd ~/dev/app && git fetch origin && git rebase origin/main && rm -rf build/"}),
        ("demo-path", "pi", "waiting", "etc hosts cleanup", {"waitingFor": "write: /etc/hosts"}),
        ("demo-ask", "pi", "idle", "fixture cleanup", {"turnState": "blocked", "ask": "keep the old fixture, or regenerate it?"}),
        ("demo-fail", "pi", "idle", "nightly bot", {"turnState": "failed", "summary": "The update bot still fails on the darwin eval."}),
        ("demo-done", "pi", "idle", "footer popup width", {"turnState": "done", "summary": "Fixed the footer popup width on narrow terminals."}),
        ("demo-busy1", "cli", "busy", "devenv-tilt-68", {}),
        ("demo-busy2", "pi", "busy", "flaky ci retries", {"doing": "rerunning the retry test"}),
        ("demo-idle1", "cli", "idle", "dotfiles-2a", {}),
        ("demo-idle2", "pi", "idle", "homelab grafana alerts", {}),
    ]
    return [
        {"sessionId": sid, "pid": 0, "kind": "interactive", "entrypoint": entry, "status": status, "name": name,
         "cwd": str(Path.home() / "dev" / sid), "statusUpdatedAt": t - 60_000 * (i + 1), **extra}
        for i, (sid, entry, status, name, extra) in enumerate(entries)
    ]


def cmd_demo(_args):
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(str(socket_path()))
    sock.sendall((json.dumps({"op": "demo", "sessions": demo_sessions()}) + "\n").encode())
    print("Demo sessions are on the bar until you press Ctrl-C.", flush=True)
    try:
        sock.recv(1)
    except KeyboardInterrupt:
        pass


def cmd_daemon(_args):
    asyncio.run(Hub(load_config()).run())


def main(argv=None):
    parser = argparse.ArgumentParser(prog="agent-hub", description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("daemon", help="serve the hub socket").set_defaults(func=cmd_daemon)
    commands.add_parser("demo", help="show fake sessions in every state on the bar").set_defaults(func=cmd_demo)
    commands.add_parser("hook", help="Claude Code Stop and PermissionRequest hook").set_defaults(func=cmd_hook)
    commands.add_parser("focus-next", help="focus the next session that wants you").set_defaults(func=cmd_focus_next)
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
