"""The hub: every live pi and Claude Code session, what it is called, what it is on and
how its last turn ended, for the bar and for each agent's own TUI.

`agent-hub daemon` serves `protocol` on its socket (`common.socket_path`). This module is
the shell around `model`: it turns the registry, pi's connection and Claude's hooks into
changes of a `Session`, runs `readings`, and publishes rows. Sessions come from the
registry (Claude Code's, which pi writes into too) and from pi's attach; Claude's hooks
can name one before the registry has it, and it is kept while its pid lives.
"""

import asyncio
import json
import os
import sys
from pathlib import Path

from . import model, peers, pi, protocol, worklog
from .common import (
    LINE_MAX, alive, label_line, log_path, now_ms, peer_uid, resume_argv, resume_command, socket_path, write_atomic,
)
from .desktop import Niri, Toasts, TOAST_GRACE_MS
from .readings import Readings, digest
from .registry import RegistrySource

RECENT_MAX = 100
# A session no longer listed anywhere is kept this long, for a registry that has yet to catch up.
UNSEEN_MS = 60_000
# How often a running turn's transcript is checked for progress.
TICK = 30


def agent_of(entry):
    return "pi" if entry.get("entrypoint") == "pi" else "claude"


class Conn:
    def __init__(self, writer):
        self.writer = writer
        self.uid = peer_uid(writer.get_extra_info("socket"))
        self.subscriber = False
        self.demo = {}
        # The session this connection is attached for.
        self.session = None
        # Judge requests out, request → the future its answer lands on.
        self.calls = {}
        self.next_call = 0
        self.pushed = None

    def send(self, payload):
        if not self.writer.is_closing():
            self.writer.write((json.dumps(payload) + "\n").encode())


class Hub:
    def __init__(self, cfg):
        self.source = RegistrySource(Path(cfg["registry"]).expanduser(), self.changed, poll=bool(cfg.get("poll")))
        self.niri = Niri(cfg.get("niri"), self.changed)
        self.toasts = Toasts(cfg, self._focus)
        self.git = peers.Git(cfg.get("git"))
        self.terminal = cfg.get("terminal")
        self.state_file = Path(cfg["state"]).expanduser()
        self.log_file = log_path(cfg)
        self.readings = Readings(self, cfg.get("claude"))
        self.conns = set()
        # Session id → the connection it is attached on.
        self.attached = {}
        self.sessions, self.recent = self._load()
        self._saved = None
        self._last = None
        # The window focus last read the `done` turns under it.
        self._read_focus = None
        self._toast_timer = None
        self._tasks = set()

    # Persistence.

    def _load(self):
        try:
            saved = json.loads(self.state_file.read_text())
        except (OSError, ValueError):
            saved = {}
        if not isinstance(saved, dict):
            saved = {}
        now = now_ms()
        sessions = {}
        for data in saved.get("sessions") or []:
            try:
                session = model.Session.load(data, now)
            except (TypeError, KeyError):
                continue
            sessions[session.id] = session
        return sessions, [r for r in saved.get("recent") or [] if isinstance(r, dict) and r.get("id")]

    def _save(self):
        """Writes the state file when what it holds changed since the last write."""
        text = json.dumps({"sessions": [s.saved() for s in self.sessions.values()], "recent": self.recent})
        if text == self._saved:
            return
        try:
            write_atomic(self.state_file, text)
            self._saved = text
        except OSError as error:
            print(f"agent-hub: can't save {self.state_file}: {error}", file=sys.stderr)

    async def run(self):
        path = socket_path()
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.unlink(missing_ok=True)
        worklog.prune(self.log_file, now_ms())
        server = await asyncio.start_unix_server(self._serve, path=str(path), limit=LINE_MAX)
        path.chmod(0o600)
        self.source.start()
        tasks = [server.serve_forever(), self.niri.run(), self._tick()]
        async with server:
            await asyncio.gather(*tasks)

    # Sessions.

    def _session(self, sid, agent="claude"):
        """The session by id, made on first word of it; one that ended takes back what it was called."""
        session = self.sessions.get(sid)
        if session is None:
            now = now_ms()
            item = next((r for r in self.recent if r["id"] == sid), None)
            if item is not None:
                self.recent.remove(item)
                session = model.Session.load(item, now)
                session.status_at = now
            else:
                session = model.Session(id=sid, agent=agent, seen=now, status_at=now)
            self.sessions[sid] = session
        return session

    def visible(self):
        """The sessions the bar shows: in the registry, or attached."""
        return {sid: self.sessions[sid] for sid in [*self.source.sessions, *self.attached] if sid in self.sessions}

    def changed(self):
        """The registry or niri moved: sync each listed session, end the ones gone, publish."""
        now = now_ms()
        for sid, entry in self.source.sessions.items():
            session = self._session(sid, agent_of(entry))
            session.agent = agent_of(entry)
            session.pid = entry.get("pid") or session.pid
            session.cwd = entry.get("cwd") or session.cwd
            if entry.get("nameSource") == "user" and entry.get("name"):
                session.name = entry["name"]
            elif sid not in self.attached:
                session.name = ""
            session.derived = "" if entry.get("nameSource") == "user" else entry.get("name") or ""
            # pi speaks for itself once attached; its entry is claude-peers' echo.
            if sid not in self.attached:
                # The entry's own stamp dates the move, so a dialog open since before a restart keeps its age.
                at = entry.get("statusUpdatedAt") or now
                if session.observe(entry.get("status"), entry.get("waitingFor"), at, registry=True) == "started":
                    self.readings.cancel(sid)
        listed = set(self.source.sessions) | set(self.attached)
        listed_pids = {self.sessions[sid].pid for sid in listed if sid in self.sessions}
        for sid, session in list(self.sessions.items()):
            if sid in listed:
                session.seen = now
            # A hook can name a session before the registry has it; its pid says whether it still runs.
            # One whose pid another session now speaks for was cleared.
            elif not session.ending and session.pid and session.pid not in listed_pids and alive({"pid": session.pid}):
                session.seen = now
            elif session.ending or session.pid or now - session.seen > UNSEEN_MS:
                self._retire(session)
        if self.niri.focused != self._read_focus:
            self._read_focus = self.niri.focused
            self._read_focused(self.visible().values())
        self.publish()

    def _read_focused(self, sessions):
        """A `done` turn whose window has focus has been read; one that asks or failed still wants you."""
        focused, now = self.niri.focused, now_ms()
        if focused is None:
            return
        for session in sessions:
            if session.state(now) == "done" and self.niri.window_of(session.pid) == focused:
                session.dismiss()

    def _retire(self, session):
        """A session that ended goes to the recent list, when it was ever named."""
        del self.sessions[session.id]
        self.readings.forget(session.id)
        if not session.label:
            return
        # What it is called, not the turn it was on or the process it ran in.
        item = {k: v for k, v in session.saved().items() if k not in ("turn", "pid", "dismissed")}
        item["endedAt"] = now_ms()
        self.recent = [item] + [r for r in self.recent if r["id"] != session.id]
        del self.recent[RECENT_MAX:]

    def turn_read(self, session, n, outcome):
        """How turn `n` ended, as `readings` made it out; None when there was nothing to read."""
        if outcome is None:
            session.reading(n, False)
        elif session.read(n, outcome, now_ms()):
            worklog.append(self.log_file, {
                **session.history[-1], "session": session.id, "agent": session.agent, "cwd": session.cwd,
                "configDir": session.config_dir, "label": session.label, "ask": outcome.get("ask") or "",
            })
            self._read_focused([session])
        self.publish()

    def notice(self, sid, text):
        conn = self.attached.get(sid)
        if conn is not None:
            conn.send({"type": "notice", "text": text})

    async def _peers(self, session, worktree_tool):
        """The note on the other sessions in this one's working tree, "" for none."""
        root = await self.git.root(session.cwd)
        if root is None:
            return ""
        others = [entry for sid, entry in self.source.sessions.items()
                  if sid != session.id and entry.get("messagingSocketPath") and await self.git.root(entry.get("cwd")) == root]
        if not others:
            return ""
        return peers.note(session.agent, root, others, await self.git.dirty(root), worktree_tool, now_ms())

    # Publishing.

    def rows(self, now):
        rows = [session.row(now, self.niri.window_of(session.pid)) for session in self.visible().values()]
        for conn in self.conns:
            for sid, entry in conn.demo.items():
                rows.append(demo_row(sid, entry))
        return model.ordered(rows)

    def state(self):
        recent = [{"id": r["id"], "agent": r.get("agent") or "claude", "label": r.get("label") or "",
                   "summary": r.get("summary") or "", "cwd": r.get("cwd") or "", "endedAt": r.get("endedAt") or 0,
                   "resume": resume_command(r.get("agent"), r["id"], r.get("cwd"), r.get("config_dir")),
                   "history": r.get("history") or []} for r in self.recent]
        return {"type": "state", "sessions": self.rows(now_ms()), "recent": recent}

    def publish(self, force_to=None):
        # Saved before anyone hears of it: a client that saw a state can count on it surviving a restart.
        self._save()
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
        rows = {row["id"]: row for row in state["sessions"]}
        for sid, conn in self.attached.items():
            session = self.sessions.get(sid)
            push = {"type": "row", "row": rows.get(sid), "identity": session.identity() if session else {}}
            if push != conn.pushed:
                conn.pushed = push
                conn.send(push)

    def _schedule_toasts(self, sessions, now):
        """Publishes again when the next dialog still in its grace period comes out of it."""
        due = [r["since"] + TOAST_GRACE_MS - now for r in sessions if r["state"] == "asking" and now - r["since"] < TOAST_GRACE_MS]
        if self._toast_timer is not None:
            self._toast_timer.cancel()
            self._toast_timer = None
        if due:
            self._toast_timer = asyncio.get_running_loop().call_later(min(due) / 1000, self.publish)

    async def _tick(self):
        """A running turn whose transcript moved made progress; one that stalls is told
        apart by what its transcript says is still running."""
        while True:
            await asyncio.sleep(TICK)
            now = now_ms()
            for session in list(self.visible().values()):
                if session.turn is None or not session.turn.open or not session.transcript:
                    continue
                try:
                    moved = int(os.stat(session.transcript).st_mtime * 1000)
                except OSError:
                    continue
                session.progress = max(session.progress, moved)
                if session.state(now) == "stalled" and session.running_checked != moved:
                    session.running_checked = moved
                    session.running = await asyncio.to_thread(digest_running, session) or ""
            self.publish()

    def _spawn(self, coro):
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    # Focus.

    def _row(self, sid):
        return next((r for r in self._last["sessions"] if r["id"] == sid), None) if self._last else None

    async def _focus(self, sid):
        row = self._row(sid)
        if row and row["window"] is not None:
            await self.niri.focus(row["window"])

    async def _focus_next(self):
        if not self._last:
            return
        targets = [r for r in self._last["sessions"] if r["state"] in protocol.ATTENTION and r["window"] is not None]
        if not targets:
            return
        at = next((i for i, r in enumerate(targets) if r["window"] == self.niri.focused), None)
        await self.niri.focus(targets[0 if at is None else (at + 1) % len(targets)]["window"])

    def _toggle(self):
        """Dismisses the finished turn of the session under the focused window, or brings back the one you dismissed."""
        if not self._last or self.niri.focused is None:
            return
        for row in self._last["sessions"]:
            session = self.sessions.get(row["id"])
            if row["window"] != self.niri.focused or session is None or session.turn is None:
                continue
            if row["state"] in model.DISMISSABLE:
                session.dismiss()
            elif session.dismissed == session.turn.n:
                session.dismissed = None
            else:
                continue
            self.publish()
            return

    # The socket.

    async def _serve(self, reader, writer):
        try:
            conn = Conn(writer)
        except OSError:
            writer.close()
            return
        if conn.uid not in (None, os.getuid()):
            writer.close()
            return
        self.conns.add(conn)
        try:
            async for line in reader:
                try:
                    message = protocol.validate(json.loads(line))
                    await self._dispatch(conn, message)
                except ValueError as error:
                    conn.send({"type": "error", "error": str(error)})
                if conn.writer.is_closing():
                    break
        except (ConnectionError, asyncio.LimitOverrunError, ValueError):
            pass
        finally:
            self.conns.discard(conn)
            writer.close()
            for future in conn.calls.values():
                if not future.done():
                    future.set_result(None)
            if conn.session is not None:
                self._detach(conn)
            elif conn.demo:
                self.publish()

    def _refuse(self, conn, version):
        conn.send({"type": "refused", "text": f"agent-hub speaks protocol {protocol.VERSION}, this session "
                                              f"{version}: restart the session to reconnect"})
        conn.writer.close()

    def _attach(self, conn, message):
        if message["version"] != protocol.VERSION:
            self._refuse(conn, message["version"])
            return
        sid = message["session"]
        if conn.session not in (None, sid):
            self._detach(conn, publish=False)
        conn.session, conn.pushed = sid, None
        self.attached[sid] = conn
        now = message["since"]
        session = self._session(sid, "pi")
        session.agent, session.pid, session.cwd = "pi", message["pid"], message["cwd"]
        session.transcript, session.leaf = message.get("transcript"), message.get("leaf")
        session.ending = False
        name = message["name"]
        session.name = name.strip() if isinstance(name, str) else ""
        # pi's branch is the authority on its own record.
        record = message["record"]
        session.label = record.get("label") or session.label
        session.summary = record.get("summary") or session.summary
        session.tags = record.get("tags") or session.tags
        session.calls = max(session.calls, record.get("calls") or 0)
        status = message["status"] if message["status"] in ("busy", "idle", "waiting") else "idle"
        if status == "waiting" and message["waitingFor"]:
            session.wait(label_line(message["waitingFor"]), now)
        else:
            session.observe(status, None, now)
        if status != "idle" and (session.turn is None or not session.turn.open):
            session.start_turn(now)
        self.changed()

    def _detach(self, conn, publish=True):
        """pi hangs up when its session ends, /new included, so a detach ends the session."""
        if self.attached.get(conn.session) is conn:
            del self.attached[conn.session]
            if conn.session in self.sessions:
                self.sessions[conn.session].ending = True
        conn.session = None
        if publish:
            self.changed()

    def _own(self, conn, message):
        """The session an agent's message is about: its connection's, or the one a hook names."""
        if conn.session is not None:
            return self.sessions.get(conn.session)
        sid = message.get("session")
        if not sid:
            raise ValueError(f"{message['op']} needs a session")
        session = self._session(sid)
        # A hook's word: who runs the session, before the registry has it.
        if message.get("pid"):
            session.pid = message["pid"]
        if message.get("cwd") and not session.cwd:
            session.cwd = message["cwd"]
        if message.get("configDir"):
            session.config_dir = message["configDir"]
        return session

    async def _turn_start(self, conn, message):
        session = self._own(conn, message)
        if session is None:
            return ""
        now = now_ms()
        if message.get("transcript"):
            session.transcript, session.leaf = message["transcript"], message.get("leaf")
        if session.start_turn(now) is not None:
            self.readings.cancel(session.id)
        session.observe("busy", None, now)
        prompt = message.get("prompt") or ""
        if message.get("fromPerson", True) and prompt.strip() and not pi.is_acknowledgement(prompt):
            self._spawn(self.readings.label(session, prompt))
        self.publish()
        note = await self._peers(session, message.get("worktreeTool", conn.session is None))
        if conn.session is not None:
            return note
        # Claude's note goes in its context, so it hears one only when it changed.
        if note == session.told:
            return ""
        session.told = note
        return note or "The other agent sessions in this working tree have closed; you have it to yourself."

    def _turn_end(self, conn, message):
        session = self._own(conn, message)
        if session is None:
            return
        now = now_ms()
        if message.get("transcript"):
            session.transcript, session.leaf = message["transcript"], message.get("leaf")
        # An ending with no turn open to end: the agent carried on unannounced, as Claude does
        # when a background job reports back, or the hub restarted mid-turn.
        if session.turn is None or (not session.turn.open and session.turn.outcome is not None):
            session.start_turn(now)
        n = session.end_turn(now)
        session.observe("idle", None, now)
        if n is not None:
            # Read before idle: the bar shows the reading, never a gap before it.
            self.readings.settle(session, n, message.get("pending") or 0, bool(message.get("error")))
        self.publish()

    async def _dispatch(self, conn, message):
        op = message["op"]
        if op == "subscribe":
            if message.get("version", protocol.VERSION) != protocol.VERSION:
                self._refuse(conn, message["version"])
                return
            conn.subscriber = True
            # The last state sent is current: anything that changes it publishes.
            if self._last is None:
                self.publish(force_to=conn)
            else:
                conn.send(self._last)
        elif op == "attach":
            self._attach(conn, message)
        elif op == "turn-start":
            peers_note = await self._turn_start(conn, message)
            if message.get("request") is not None:
                conn.send({"type": "reply", "request": message["request"], "peers": peers_note})
        elif op == "turn-end":
            self._turn_end(conn, message)
        elif op == "dialog":
            session = self._own(conn, message)
            if session is not None:
                if message["text"]:
                    session.wait(label_line(message["text"]), now_ms())
                else:
                    session.observe("busy", None, now_ms())
                self.publish()
        elif op == "named":
            session = self._own(conn, message)
            if session is not None:
                session.name = (message["name"] or "").strip()
                self.publish()
        elif op == "relabel":
            session = self._own(conn, message)
            if session is not None:
                self._spawn(self.readings.label(session, manual=True))
        elif op == "judged":
            future = conn.calls.get(message["request"])
            if future is not None and not future.done():
                future.set_result(message.get("text"))
        elif op == "session-start":
            self._own(conn, message).ending = False
            self.publish()
        elif op == "session-end":
            session = self.sessions.get(message["session"])
            if session is not None:
                session.ending = True
                self.changed()
        elif op == "focus":
            await self._focus(message["session"])
        elif op == "focus-next":
            await self._focus_next()
        elif op == "dismiss":
            row, session = self._row(message["session"]), self.sessions.get(message["session"])
            if row and session and row["state"] in model.DISMISSABLE and session.dismiss():
                self.publish()
        elif op == "toggle":
            self._toggle()
        elif op == "resume":
            item = next((r for r in self.recent if r["id"] == message["session"]), None)
            if item is not None and self.terminal:
                cwd = item.get("cwd") or str(Path.home())
                await self.niri.spawn([arg.replace("{cwd}", cwd) for arg in self.terminal]
                                      + resume_argv(item.get("agent"), item["id"], item.get("config_dir")))
        elif op == "demo":
            conn.demo = {str(e["sessionId"]): e for e in message["sessions"] if isinstance(e, dict) and e.get("sessionId")}
            self.publish()


def digest_running(session):
    """The command a turn's transcript shows still running, or None."""
    found = digest(session) or {}
    last = (found.get("commands") or [""])[-1]
    return last if last and not last.endswith(("(ok)", "(failed)")) else None


def demo_row(sid, entry):
    """A fake session for `agent-hub demo`, from a registry-shaped entry."""
    t = entry.get("statusUpdatedAt") or 0
    session = model.Session(id=sid, agent=agent_of(entry), cwd=entry.get("cwd") or "", derived=entry.get("name") or "",
                            label=entry.get("label") or "", status_at=t, progress=now_ms())
    status = entry.get("status")
    if status == "waiting":
        session.wait(entry.get("waitingFor") or "", t)
    elif status == "busy":
        session.turn = model.Turn(n=1, started=t, doing=entry.get("doing") or "")
    elif entry.get("turnState"):
        session.turn = model.Turn(n=1, started=t, ended=t, outcome={
            "state": entry["turnState"], "ask": entry.get("ask") or "", "reply": "",
            "summary": entry.get("summary") or "", "jobs": 0})
    return session.row(now_ms())
