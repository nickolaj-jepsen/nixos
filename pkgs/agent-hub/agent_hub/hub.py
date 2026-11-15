"""The hub: every live pi and Claude Code session and whether it wants you, for the bar.

`agent-hub daemon` serves `protocol` on its socket (`common.socket_path`). This module is
the shell around `model`: it turns the registry and Claude's three hooks into changes of a
`Session`, and publishes rows. Sessions come from the registry (Claude Code's, which pi
writes into too); Claude's hooks can name one before the registry has it, and it is kept
while its pid lives. Nothing is kept on disk: after a restart the hub rebuilds from the
registry alone.
"""

import asyncio
import json
import os
import sys
from pathlib import Path

from . import links, model, protocol, repo
from .claude import TitleTail
from .common import LINE_MAX, alive, hidden_by_env, label_line, now_ms, peer_uid, socket_path
from .desktop import Desktop
from .registry import RegistrySource

# A session no longer listed anywhere is kept this long, for a registry that has yet to catch up.
UNSEEN_MS = 60_000
UNDO_MAX = 50
DEMO_DETAILS = ("project",)


def agent_of(entry):
    return "pi" if entry.get("entrypoint") == "pi" else "claude"


class Conn:
    def __init__(self, writer):
        self.writer = writer
        self.uid = peer_uid(writer.get_extra_info("socket"))
        self.subscriber = False
        # Subscribed to this host's own sessions only: a viewer on another host.
        self.local = False
        self.demo = {}

    def send(self, payload):
        if not self.writer.is_closing():
            self.writer.write((json.dumps(payload) + "\n").encode())


class Hub:
    def __init__(self, cfg):
        self.source = RegistrySource(Path(cfg["registry"]).expanduser(), self.changed, poll=bool(cfg.get("poll")))
        self.desktop = Desktop(cfg.get("niri"), self.changed)
        self.git = cfg.get("git")
        self.terminal = cfg.get("terminal")
        # Session id → its transcript as far as it has been read, for the title.
        self.tails = {}
        self.conns = set()
        self.sessions = {}
        self.alerts = model.Alerts()
        # The other hosts piped in, and what each has announced here.
        self.links = {host: links.Link(host, cfg.get("ssh") or "ssh", cfg.get("sshConfig") or "none", self.publish)
                      for host in cfg.get("remotes") or []}
        self.link_alerts = {host: model.Alerts() for host in self.links}
        self._last_local = None
        self._alert_timer = None
        # Session id → the state the journal last said it was in.
        self._logged = {}
        self._last = None
        # The window focus last read the `done` turns under it.
        self._read_focus = None
        self._tasks = set()
        # What was dismissed at this hub's bar, oldest first, for `undo`. Memory only.
        self.dismissals = []
        # Remote row id → the ending hidden at this viewer. The far host is never told.
        self.remote_hidden = {}

    async def run(self):
        path = socket_path()
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.unlink(missing_ok=True)
        server = await asyncio.start_unix_server(self._serve, path=str(path), limit=LINE_MAX)
        path.chmod(0o600)
        self.source.start()
        tasks = [server.serve_forever(), self.desktop.run(), *(link.run() for link in self.links.values())]
        async with server:
            await asyncio.gather(*tasks)

    # Sessions.

    def _session(self, sid, agent="claude"):
        """The session by id, made on first word of it."""
        session = self.sessions.get(sid)
        if session is None:
            now = now_ms()
            session = self.sessions[sid] = model.Session(id=sid, agent=agent, seen=now, status_at=now)
        return session

    def visible(self):
        """The sessions the bar shows: the ones in the registry."""
        return {sid: self.sessions[sid] for sid in self.source.sessions if sid in self.sessions}

    def changed(self):
        """The registry or niri moved: sync each listed session, end the ones gone, publish."""
        now = now_ms()
        for sid, entry in self.source.sessions.items():
            session = self._session(sid, agent_of(entry))
            session.agent = agent_of(entry)
            session.pid = entry.get("pid") or session.pid
            if entry.get("cwd") and entry["cwd"] != session.cwd:
                session.cwd, session.git_asked = entry["cwd"], False
            if entry.get("nameSource") == "user" and entry.get("name"):
                session.name = entry["name"]
            else:
                session.name = ""
            session.derived = "" if entry.get("nameSource") == "user" else entry.get("name") or ""
            session.bridge = entry.get("bridgeSessionId") or ""
            at = entry.get("statusUpdatedAt") or now
            if session.agent == "pi":
                session.hidden = bool(entry.get("hubHidden"))
                session.tmux = entry.get("tmux") or ""
                self._observe_pi(session, entry, at)
            else:
                # Only /proc can say, and only when the session is first seen; a hook says it elsewhere.
                if not session.env_read and session.pid:
                    session.env_read = True
                    session.hidden = session.hidden or hidden_by_env(session.pid)
                moved = session.observe(entry.get("status"), entry.get("waitingFor"), at, registry=True)
                if moved == "busy":
                    asyncio.get_running_loop().call_later(model.REGISTRY_GRACE_MS / 1000, self.changed)
                session.registry_turn(now)
        for session in self.visible().values():
            if not session.git_asked and session.cwd:
                self._spawn(self._ask_project(session))
        listed = set(self.source.sessions)
        listed_pids = {self.sessions[sid].pid for sid in listed if sid in self.sessions}
        for sid, session in list(self.sessions.items()):
            if sid in listed:
                session.seen = now
            # A hook can name a session before the registry has it; its pid says whether it still runs.
            # One whose pid another session now speaks for was cleared.
            elif session.pid:
                if session.pid in listed_pids or not alive({"pid": session.pid}):
                    self._retire(session)
            elif now - session.seen > UNSEEN_MS:
                self._retire(session)
        if self.desktop.focused != self._read_focus:
            self._read_focus = self.desktop.focused
            self._read_focused(self.visible().values())
        self.publish()

    def _observe_pi(self, session, entry, at):
        """pi reports through its registry entry alone: busy while a turn runs, idle when it is
        over (`hubFailed` says it failed), and `hubPeer` when a peer's message woke it."""
        status, failed, peer = entry.get("status"), entry.get("hubFailed"), bool(entry.get("hubPeer"))
        seen = (status, entry.get("waitingFor"), at, failed, peer)
        if seen == session.pi_seen:
            return
        session.pi_seen = seen
        if status == "busy":
            if peer:
                session.start_aside(at)
            elif session.turn is None or not session.turn.open:
                session.start_turn(at)
            session.observe("busy", None, at)
        elif status == "idle":
            outcome = model.ending(failure=label_line(failed) if isinstance(failed, str) and failed else "")
            # A failure is never missed: a turn too short for its start to have been seen still failed.
            if outcome["state"] == "failed" and session.aside is None and (session.turn is None or not session.turn.open):
                session.start_turn(at)
            if session.aside is not None:
                session.end_aside(outcome, at)
            elif session.turn is not None and session.turn.open:
                self._end_turn(session, outcome)
            session.observe("idle", None, at)
        else:
            session.observe(status, entry.get("waitingFor"), at, registry=True)

    def _read_focused(self, sessions):
        """A `done` turn whose window has focus has been read; one that asks or failed still wants you."""
        focused, now = self.desktop.focused, now_ms()
        if focused is None:
            return
        for session in sessions:
            if session.state(now) == "done" and self.desktop.window_of(session.pid) == focused:
                session.dismiss()

    def _retire(self, session):
        del self.sessions[session.id]
        self.tails.pop(session.id, None)

    def _end_turn(self, session, outcome):
        """The open turn ends as `outcome` says, unless it already has an ending."""
        if session.end_turn(now_ms(), outcome):
            self._read_focused([session])

    def _title(self, session):
        """Claude's own name for the session, from its transcript, which is read on the hooks
        and when the popout opens, nowhere else."""
        if not session.transcript:
            return
        tail = self.tails.get(session.id)
        if tail is None or tail.path != session.transcript:
            tail = self.tails[session.id] = TitleTail(session.transcript)
        tail.advance()
        session.title = tail.title

    async def _ask_project(self, session):
        """The repository a session is in, asked of git once; publishes when it moved."""
        session.git_asked = True
        if not session.cwd:
            return
        project = await repo.project(self.git, session.cwd)
        if project != session.project:
            session.project = project
            self.publish()

    # Publishing.

    def rows(self, now):
        rows = [session.row(now, self.desktop.window_of(session.pid)) for session in self.visible().values()]
        for conn in self.conns:
            for sid, entry in conn.demo.items():
                rows.append(demo_row(sid, entry))
        return model.ordered(rows)

    def state(self, rows):
        """The `state` message: the rows the bar shows, and how many are hidden."""
        shown = [row for row in rows if not row.get("hidden")]
        return {"type": "state", "sessions": shown, "hidden": len(rows) - len(shown)}

    def _with_links(self, local, now):
        """The state with what the other hubs say: this host's order holds across them all, and
        each host's turns are announced by what this hub knew of that host."""
        rows = list(local["sessions"])
        due = []
        for host, link in self.links.items():
            # Copies: `pulse` must show as a change against the state last sent.
            copies = [dict(row) for row in link.rows]
            if link.status == "up":
                for rid in [rid for rid in self.remote_hidden if links.split_id(rid)[0] == host]:
                    if rid not in {row["id"] for row in copies}:
                        del self.remote_hidden[rid]
            for row in copies:
                key = model.alert_key(row)
                if key is None:
                    self.remote_hidden.pop(row["id"], None)
                elif self.remote_hidden.get(row["id"]) == key:
                    row.update({"state": "idle", "reason": ""})
            # A link that's down has no rows, and says nothing about what is known of that host.
            if link.status == "up":
                due.append(self.link_alerts[host].update(copies, now))
            rows += copies
        return {**local, "sessions": model.ordered(rows),
                "links": [link.view() for link in self.links.values()]}, [d for d in due if d is not None]

    def publish(self, force_to=None):
        now = now_ms()
        rows = self.rows(now)
        shown = [row for row in rows if not row.get("hidden")]
        due = self.alerts.update(shown, now, self.desktop.focused, keep=self.sessions)
        self._journal(rows)
        local = self.state(rows)
        state, link_due = self._with_links(local, now)
        self._schedule_alerts(min([d for d in (due, *link_due) if d is not None], default=None))
        for conn in self.conns:
            if conn.subscriber and conn is not force_to and not conn.local and state != self._last:
                conn.send(state)
            elif conn.subscriber and conn is not force_to and conn.local and local != self._last_local:
                conn.send(local)
        self._last, self._last_local = state, local
        if force_to is not None:
            force_to.send(local if force_to.local else state)

    def _schedule_alerts(self, due):
        """Publishes again when a pulse is due to start or stop by itself."""
        if self._alert_timer is not None:
            self._alert_timer.cancel()
            self._alert_timer = None
        if due is not None:
            self._alert_timer = asyncio.get_running_loop().call_later(due / 1000, self.publish)

    def _journal(self, rows):
        """One line per state change. Never the words: a homelab journal ships to Grafana Cloud.
        A turn gone straight to idle says why: `read` (focus put away its ending) or `interrupted`."""
        states = {row["id"]: row["state"] for row in rows}
        for sid, state in states.items():
            old = self._logged.get(sid)
            if state == old or (old is None and state not in protocol.ATTENTION):
                continue
            session = self.sessions.get(sid)
            turn = session.turn if session else None
            why = ""
            if state == "idle" and old == "working" and turn is not None and not turn.open:
                why = " (read)" if turn.outcome else " (interrupted)"
            print(f"agent-hub: {sid[:8]} {old or 'new'} -> {state}{why}", file=sys.stderr, flush=True)
        self._logged = states

    def _spawn(self, coro):
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    # Focus.

    def _row(self, sid):
        return next((r for r in self._last["sessions"] if r["id"] == sid), None) if self._last else None

    async def _focus(self, sid):
        """Goes to a session: its window here, or, for one on another host, its tmux pane in a new
        terminal or its Remote Control page, and its ending is hidden at this viewer."""
        row = self._row(sid)
        if not row:
            return
        if row["window"] is not None:
            await self.desktop.focus(row["window"])
            return
        if not row.get("host"):
            return
        if row.get("tmux"):
            await self._terminal(None, ["ssh", "-t", row["host"], "tmux", "attach", "-t", row["tmux"]])
        elif row.get("bridge"):
            await self.desktop.spawn(["xdg-open", f"https://claude.ai/code/{row['bridge']}"])
        else:
            return
        self._alerts_of(sid).opened.add(sid)
        self._dismiss(sid, None)

    async def _terminal(self, cwd, argv):
        """Opens `argv` in the configured terminal, through niri so it gets the desktop's environment."""
        if self.terminal:
            cwd = cwd or str(Path.home())
            await self.desktop.spawn([arg.replace("{cwd}", cwd) for arg in self.terminal] + argv)

    async def _focus_next(self):
        if not self._last:
            return
        targets = [r for r in self._last["sessions"] if r["state"] in protocol.ATTENTION and r["window"] is not None]
        if not targets:
            return
        at = next((i for i, r in enumerate(targets) if r["window"] == self.desktop.focused), None)
        await self.desktop.focus(targets[0 if at is None else (at + 1) % len(targets)]["window"])

    def _toggle(self):
        """Dismisses the finished turn of the session under the focused window, or brings back the one you dismissed."""
        if not self._last or self.desktop.focused is None:
            return
        for row in self._last["sessions"]:
            session = self.sessions.get(row["id"])
            if row["window"] != self.desktop.focused or session is None or session.turn is None:
                continue
            if row["state"] in model.DISMISSABLE:
                session.dismiss()
            elif session.dismissed == session.turn.n:
                session.dismissed = None
            else:
                continue
            self.publish()
            return

    def _alerts_of(self, sid):
        """The `Alerts` that row `sid` is announced by."""
        return self.link_alerts.get(links.split_id(sid)[0], self.alerts)

    def _dismiss(self, sid, turn):
        """Puts away a finished turn or an open prompt: here, or, for a row from another host, at
        this viewer only. Naming a turn, only that one."""
        row, session = self._row(sid), self.sessions.get(sid)
        if not (row and row["state"] in protocol.ATTENTION) or (turn is not None and row.get("turn") != turn):
            return
        key = model.alert_key(row)
        if links.split_id(sid)[0] in self.links:
            self.remote_hidden[sid] = key
        elif not (session and session.dismiss()):
            return
        self.dismissals = [*self.dismissals, {"session": sid, "turn": row.get("turn"), "key": key}][-UNDO_MAX:]
        self.publish()

    def _undo(self):
        """Brings back the last dismissal at this bar that still stands. One whose session has
        started a new turn, or that is back already, is dropped along the way."""
        while self.dismissals:
            entry = self.dismissals.pop()
            sid, turn, key = entry["session"], entry["turn"], entry["key"]
            row = self._row(sid)
            if not row or row.get("turn") != turn or model.alert_key(row) == key:
                continue
            if links.split_id(sid)[0] in self.links:
                if self.remote_hidden.get(sid) != key:
                    continue
                del self.remote_hidden[sid]
                self.link_alerts[links.split_id(sid)[0]].expect(sid, key)
                self.publish()
                return
            session = self.sessions.get(sid)
            if session and session.undismiss(turn):
                self.alerts.expect(sid, model.alert_key(session.row(now_ms())))
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
                    await self._dispatch(conn, protocol.validate(json.loads(line)))
                except ValueError as error:
                    conn.send({"type": "error", "error": str(error)})
                if conn.writer.is_closing():
                    break
        except (ConnectionError, asyncio.LimitOverrunError, ValueError):
            pass
        finally:
            self.conns.discard(conn)
            writer.close()
            if conn.demo:
                self.publish()

    def _own(self, message):
        """The session a hook's message is about, with what the hook says of who runs it."""
        session = self._session(message["session"])
        if message.get("pid"):
            session.pid = message["pid"]
        if message.get("cwd") and not session.cwd:
            session.cwd = message["cwd"]
        if message.get("hidden"):
            session.hidden = True
        if message.get("tmux"):
            session.tmux = message["tmux"]
        if message.get("transcript"):
            session.transcript = message["transcript"]
        return session

    def _turn_start(self, message):
        session = self._own(message)
        now = now_ms()
        if message.get("peer"):
            session.start_aside(now)
        else:
            session.start_turn(now)
        session.observe("busy", None, now)
        self._title(session)
        self.publish()

    def _turn_end(self, message):
        session = self._own(message)
        now = now_ms()
        self._title(session)
        outcome = model.ending(message.get("said") or "", message.get("tasks") or (), message.get("failure") or "")
        if session.aside is not None:
            session.end_aside(outcome, now)
            session.observe("idle", None, now)
            self.publish()
            return
        # An ending with no turn open to end: the agent carried on unannounced, as Claude does
        # when a background job reports back, or the hub restarted mid-turn.
        if session.turn is None or (not session.turn.open and session.turn.outcome is not None):
            session.start_turn(now)
        self._end_turn(session, outcome)
        session.observe("idle", None, now)
        self.publish()

    async def _dispatch(self, conn, message):
        op = message["op"]
        if op == "subscribe":
            conn.subscriber = True
            conn.local = bool(message.get("local"))
            # The last state sent is current: anything that changes it publishes.
            if self._last is None:
                self.publish(force_to=conn)
            else:
                conn.send(self._last_local if conn.local else self._last)
        elif op == "turn-start":
            self._turn_start(message)
        elif op == "turn-end":
            self._turn_end(message)
        elif op == "focus":
            await self._focus(message["session"])
        elif op == "focus-next":
            await self._focus_next()
        elif op == "dismiss":
            self._dismiss(message["session"], message.get("turn"))
        elif op == "undo":
            self._undo()
        elif op == "seen":
            self.alerts.seen()
            for alerts in self.link_alerts.values():
                alerts.seen()
            for session in self.visible().values():
                self._title(session)
            self.publish()
        elif op == "toggle":
            self._toggle()
        elif op == "demo":
            conn.demo = {str(e["sessionId"]): e for e in message["sessions"] if isinstance(e, dict) and e.get("sessionId")}
            self.publish()


def demo_row(sid, entry):
    """A fake session for `agent-hub demo`, from a registry-shaped entry."""
    t = entry.get("statusUpdatedAt") or 0
    session = model.Session(id=sid, agent=agent_of(entry), cwd=entry.get("cwd") or "", derived=entry.get("name") or "",
                            status_at=t)
    status = entry.get("status")
    if status == "waiting":
        session.status, session.dialog = "waiting", entry.get("waitingFor") or ""
    elif status == "busy":
        session.turn = model.Turn(n=1, started=t)
    elif entry.get("turnState"):
        failed = entry["turnState"] == "failed"
        session.turn = model.Turn(n=1, started=t, ended=t, outcome=model.ending(
            entry.get("said") or "", failure=entry.get("summary") or "API error" if failed else ""))
    row = session.row(now_ms())
    row.update({key: entry[key] for key in DEMO_DETAILS if key in entry})
    return row
