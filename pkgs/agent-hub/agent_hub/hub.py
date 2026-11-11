"""The hub: every live pi and Claude Code session, what it is on and how its last turn
ended, for the bar and for each agent's own TUI.

`agent-hub daemon` serves `protocol` on its socket (`common.socket_path`). This module is
the shell around `model`: it turns the registry, pi's connection and Claude's hooks into
changes of a `Session`, and publishes rows. Sessions come from the
registry (Claude Code's, which pi writes into too) and from pi's attach; Claude's hooks
can name one before the registry has it, and it is kept while its pid lives.
"""

import asyncio
import json
import os
import shlex
import shutil
import sys
from pathlib import Path

from . import links, menus, model, peers, protocol, worklog
from .common import (
    LINE_MAX, alive, folded, label_line, log_path, now_ms, peer_uid, resume_argv, resume_command, socket_path, write_atomic,
)
from .desktop import Desktop
from .progress import Tail
from .registry import RegistrySource

RECENT_MAX = 100
# A session no longer listed anywhere is kept this long, for a registry that has yet to catch up.
UNSEEN_MS = 60_000
UNDO_MAX = 50
PROMPT_MAX = 500
# How often a working session's transcript is looked at, and how often its row is sent regardless.
PROGRESS_S = 2
ACTIVITY_S = 15
DEMO_DETAILS = ("prompt", "permission", "project", "branch", "changed", "peers", "activity", "jobs", "history", "now", "nowAt", "counts", "trail")
# The command behind a folder menu's app, the first one found. The editors' commands come
# from menus.EDITORS, which also knows the argv that opens a path in each.
APP_COMMANDS = {**{name: spec["commands"] for name, spec in menus.EDITORS.items()}, "smerge": ("smerge",), "files": ("nautilus", "xdg-open"), "ghostty": ("ghostty",)}


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
        # The session this connection is attached for.
        self.session = None
        self.pushed = None

    def send(self, payload):
        if not self.writer.is_closing():
            self.writer.write((json.dumps(payload) + "\n").encode())


class Hub:
    def __init__(self, cfg):
        self.source = RegistrySource(Path(cfg["registry"]).expanduser(), self.changed, poll=bool(cfg.get("poll")))
        self.desktop = Desktop(cfg.get("niri"), self.changed)
        self.git = peers.Git(cfg.get("git"))
        self.terminal = cfg.get("terminal")
        # fireproof.desktop.editor: the folder menu's first row.
        self.editor = cfg.get("editor") if cfg.get("editor") in menus.EDITORS else "zed"
        self.gh = cfg.get("gh") or shutil.which("gh")
        # Where a desktop's apps are, which a user unit's own PATH doesn't reach.
        self.app_path = os.pathsep.join(cfg["appPath"]) if cfg.get("appPath") else None
        self.state_file = Path(cfg["state"]).expanduser()
        self.log_file = log_path(cfg)
        # Session id → its transcript as far as it has been followed.
        self.tails = {}
        self.conns = set()
        # Session id → the connection it is attached on.
        self.attached = {}
        self.sessions, self.recent, known, linked = self._load()
        self.alerts = model.Alerts(known)
        # The other hosts piped in, and what each has announced here.
        self.links = {host: links.Link(host, cfg.get("ssh") or "ssh", cfg.get("sshConfig") or "none", self.publish)
                      for host in cfg.get("remotes") or []}
        self.link_alerts = {host: model.Alerts(linked.get(host)) for host in self.links}
        self._last_local = None
        self._alert_timer = None
        # Session id → the state the journal last said it was in.
        self._logged = {}
        self._saved = None
        self._last = None
        # The window focus last read the `done` turns under it.
        self._read_focus = None
        self._tasks = set()
        # What was dismissed at this hub's bar, oldest first, for `undo`. Memory only.
        self.dismissals = []
        # Hold id → the hook's connection and request, which its answer goes back on.
        self.held = {}
        self.next_hold = 0

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
        known = saved.get("alerts") if isinstance(saved.get("alerts"), dict) else None
        linked = saved.get("linkAlerts") if isinstance(saved.get("linkAlerts"), dict) else {}
        return sessions, [r for r in saved.get("recent") or [] if isinstance(r, dict) and r.get("id")], known, linked

    def _save(self):
        """Writes the state file when what it holds changed since the last write."""
        text = json.dumps({"sessions": [s.saved() for s in self.sessions.values()], "recent": self.recent,
                           "alerts": self.alerts.known,
                           "linkAlerts": {host: alerts.known for host, alerts in self.link_alerts.items()}})
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
        tasks = [server.serve_forever(), self.desktop.run(), self._watch_activity(), *(link.run() for link in self.links.values())]
        async with server:
            await asyncio.gather(*tasks)

    async def _watch_activity(self):
        """Nothing else says a working session is still moving, so its transcript is followed and
        its row is looked at again."""
        ticks = 0
        while True:
            await asyncio.sleep(PROGRESS_S)
            ticks += 1
            moved = self._follow_transcripts()
            due = ticks % (ACTIVITY_S // PROGRESS_S) == 0
            working = [session for session in self.visible().values() if session.turn is not None and session.turn.open]
            if moved or (due and working):
                self.publish()

    def _follow_transcripts(self):
        """Reads on in each working session's transcript; returns whether any progress moved."""
        now, moved = now_ms(), False
        for session in self.visible().values():
            turn = session.turn
            if turn is not None and (turn.open or (turn.outcome or {}).get("jobs")):
                moved = self._tail(session, now) or moved
        return moved

    def _tail(self, session, now):
        """Reads on in a session's transcript; returns whether its progress moved."""
        if not session.transcript:
            return False
        tail = self.tails.get(session.id)
        if tail is None or tail.path != session.transcript:
            tail = self.tails[session.id] = Tail(session.transcript, session.agent, session.cwd)
        moved = tail.advance(now)
        if tail.progress.title and tail.progress.title != session.title:
            session.title, moved = tail.progress.title, True
        return moved

    def _said(self, session, said):
        """The closing words: the agent's own, else the end of its transcript, which can lag. The
        transcript is read on either way, for a title written after the last look."""
        self._tail(session, now_ms())
        tail = self.tails.get(session.id)
        return said or (tail.progress.said if tail else "")

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
            if entry.get("cwd") and entry["cwd"] != session.cwd:
                session.cwd, session.git_asked = entry["cwd"], False
            if entry.get("nameSource") == "user" and entry.get("name"):
                session.name = entry["name"]
            elif sid not in self.attached:
                session.name = ""
            session.derived = "" if entry.get("nameSource") == "user" else entry.get("name") or ""
            session.bridge = entry.get("bridgeSessionId") or ""
            # pi speaks for itself once attached; its entry is claude-peers' echo.
            if sid not in self.attached:
                # The entry's own stamp dates the move, so a dialog open since before a restart keeps its age.
                at = entry.get("statusUpdatedAt") or now
                moved = session.observe(entry.get("status"), entry.get("waitingFor"), at, registry=True)
                if moved == "busy":
                    asyncio.get_running_loop().call_later(model.REGISTRY_GRACE_MS / 1000, self.changed)
                session.registry_turn(now)
                # pi's ending is settled once it attaches.
                if session.agent != "pi":
                    self._recover(session)
                self._settle_holds(session)
        for session in self.visible().values():
            if not session.git_asked and session.cwd:
                self._spawn(self._ask_git(session))
        listed = set(self.source.sessions) | set(self.attached)
        listed_pids = {self.sessions[sid].pid for sid in listed if sid in self.sessions}
        for sid, session in list(self.sessions.items()):
            if sid in listed:
                session.seen = now
            elif session.ending:
                self._retire(session)
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

    def _recover(self, session):
        """A turn the last daemon left open: one its agent has since finished ends, by its
        transcript, since its ending went unheard. The first word after a restart settles it."""
        turn = session.turn
        if turn is None or not turn.restored:
            return
        turn.restored = False
        if session.status == "idle":
            self._end_turn(session, model.ending(self._said(session, "")))

    def _read_focused(self, sessions):
        """A `done` turn whose window has focus has been read; one that asks or failed still wants you."""
        focused, now = self.desktop.focused, now_ms()
        if focused is None:
            return
        for session in sessions:
            if session.state(now) == "done" and self.desktop.window_of(session.pid) == focused:
                session.dismiss()

    def _retire(self, session):
        """A session that ended goes to the recent list, when it ever finished a turn."""
        self._release_all(session)
        del self.sessions[session.id]
        self.tails.pop(session.id, None)
        if not session.history:
            return
        # What it is called, not the turn it was on or the process it ran in.
        item = {k: v for k, v in session.saved().items() if k not in ("turn", "pid", "dismissed")}
        item["name"], item["project"], item["endedAt"] = session.shown_name(), session.project, now_ms()
        self.recent = [item] + [r for r in self.recent if r["id"] != session.id]
        del self.recent[RECENT_MAX:]

    def _end_turn(self, session, outcome):
        """The open turn ends as `outcome` says, unless it already has an ending."""
        if session.end_turn(now_ms(), outcome):
            worklog.append(self.log_file, {**session.history[-1], **self._log_fields(session), "turn": session.turn.n})
            self._read_focused([session])

    def _log_fields(self, session):
        return {"session": session.id, "agent": session.agent, "cwd": session.cwd, "configDir": session.config_dir,
                "name": session.shown_name()}

    async def _peers(self, session, worktree_tool):
        """The note on the other sessions in this one's working tree, "" for none."""
        root = await self.git.root(session.cwd)
        if root is None:
            return ""
        others = [entry for sid, entry in self.source.sessions.items()
                  if sid != session.id and entry.get("messagingSocketPath") and not self._hidden(sid)
                  and await self.git.root(entry.get("cwd")) == root]
        if not others:
            return ""
        return peers.note(session.agent, root, others, await self.git.dirty(root), worktree_tool, now_ms())

    def _hidden(self, sid):
        return sid in self.sessions and self.sessions[sid].hidden

    async def _ask_git(self, session):
        """What git says of a session's checkout, for its row; publishes when that moved."""
        session.git_asked = True
        if not session.cwd:
            return
        root = await self.git.root(session.cwd)
        project = await self.git.project(session.cwd)
        branch, changed = await self.git.summary(session.cwd)
        if (root, project, branch, changed) != (session.root, session.project, session.branch, session.changed):
            session.root, session.project, session.branch, session.changed = root or "", project or "", branch, changed
            self.publish()

    # Prompts a hook holds open.

    def _permission(self, conn, message):
        """Claude's hook shows a prompt and stays on the line: the bar can answer it, while
        Claude's own dialog stays open in the terminal, and whichever comes first wins."""
        session = self._own(conn, message)
        self.next_hold += 1
        self.held[self.next_hold] = (conn, message["request"])
        session.hold(self.next_hold, message["ask"], label_line(message["text"]), now_ms())
        self._spawn(self._ask_git(session))
        self.publish()

    def _release(self, session, hold, decision=None):
        """Lets a hook go, with what to tell Claude; without a decision it says nothing."""
        session.unhold(hold)
        conn, request = self.held.pop(hold["id"], (None, None))
        if conn is not None:
            conn.send({"type": "reply", "request": request, **({"decision": decision} if decision else {})})

    def _release_all(self, session):
        for hold in list(session.holds):
            self._release(session, hold)

    def _settle_holds(self, session):
        for hold in session.closed_holds():
            self._release(session, hold)

    def _forget_holds(self, conn):
        """A hook hung up, so what it held can no longer be answered."""
        forgot = False
        for session in self.sessions.values():
            for hold in [h for h in session.holds if self.held.get(h["id"], (None,))[0] is conn]:
                self.held.pop(hold["id"], None)
                session.unhold(hold)
                forgot = True
        if forgot:
            self.publish()

    def _answer(self, sid, ask, allow, viewer=True):
        """Settles the prompt `ask` names, here or on the host it belongs to, as long as it is the
        one showing. Only all of what you could read can be allowed."""
        row = self._row(sid)
        permission = (row or {}).get("permission")
        if not permission or permission["id"] != ask or (allow and not permission["complete"]):
            return
        decision = "allow" if allow else "deny"
        host, own = links.split_id(sid)
        session = self.sessions.get(sid)
        if host not in self.links and not (session and session.holds):
            return
        if host in self.links:
            self.links[host].send({"op": "answer", "session": own, "ask": ask, "allow": allow})
            return
        self._release(session, session.holds[0], decision)
        # Claude moves on as soon as it has the answer; its registry entry says so a moment later.
        if not session.holds:
            session.observe("busy", None, now_ms())
        self.publish()

    # Menus.

    def _place(self, sid):
        """(host, cwd) of a row or an ended session, the host None when it is this one, or None."""
        last = self._last or {}
        item = next((r for r in [*last.get("sessions", []), *last.get("recent", [])] if r["id"] == sid), None)
        cwd = (item or {}).get("cwd") or ""
        if not cwd.startswith("/"):
            return None
        host = links.split_id(sid)[0]
        return (host if host in self.links else None), cwd

    def _can_run(self, app):
        if app == "ghostty":
            return bool(self.terminal)
        return any(shutil.which(command, path=self.app_path) for command in APP_COMMANDS[app])

    async def _git_facts(self, sid):
        """What git says of a row's checkout, from its own host, or None. Another host's word
        comes back as plain text, and every URL is built here from it."""
        place = self._place(sid)
        if place is None:
            return None
        host, cwd = place
        if host is None:
            return await asyncio.to_thread(menus.facts, self.git.exe, cwd)
        reply = await self.links[host].call({"op": "git-facts", "session": links.split_id(sid)[1]})
        said = (reply or {}).get("facts")
        if not isinstance(said, dict):
            return None
        keys = ("branch", "oid", "remote", "base")
        return {**{key: links.text(said.get(key)) for key in keys}, "upstream": said.get("upstream") is True}

    async def _menu(self, conn, message):
        """Answers with a row's menu, and again once GitHub has said what pull request it has."""
        request, sid = message["request"], message["session"]
        place = self._place(sid)
        if place is None:
            conn.send({"type": "menu", "request": request, "menu": None})
            return
        if message["which"] == "folder":
            conn.send({"type": "menu", "request": request, "menu": menus.folder_menu(place[1], place[0], self._can_run, self.editor)})
            return
        found = await self._git_facts(sid)
        if found is None:
            conn.send({"type": "menu", "request": request, "menu": None})
            return
        conn.send({"type": "menu", "request": request, "menu": menus.git_menu(found)})
        remote = menus.parse_remote(found["remote"])
        if remote and remote["forge"] == "github" and found["branch"]:
            pr, known, missing = await menus.pull_request(self.gh, remote, found["branch"])
            conn.send({"type": "menu", "request": request, "menu": menus.git_menu(found, pr, known, missing)})

    async def _reply_facts(self, conn, message):
        found = await self._git_facts(message["session"])
        conn.send({"type": "reply", "request": message["request"], "facts": found})

    async def _run(self, message):
        """Does what a menu row says, through niri as Mod+Return is, for the desktop's environment."""
        kind, value = message["kind"], message["value"]
        if kind == "url" and value.startswith("https://"):
            await self.desktop.spawn(["xdg-open", value])
        elif kind == "copy":
            await self.desktop.spawn(["wl-copy", "--", value])
        elif kind == "app" and value in APP_COMMANDS:
            await self._open_app(message["session"], value)

    async def _open_app(self, sid, app):
        place = self._place(sid)
        if place is None or not self._can_run(app):
            return
        host, cwd = place
        if app == "ghostty":
            if host:
                await self._terminal(None, ["ssh", "-t", host, f'cd {shlex.quote(cwd)} && exec "$SHELL" -l'])
            else:
                await self.desktop.spawn(["ghostty", f"--working-directory={cwd}"])
            return
        command = next(c for c in APP_COMMANDS[app] if shutil.which(c, path=self.app_path))
        if host:
            # Only an editor and Ghostty reach another host; the menu blocks the rest.
            if app in menus.EDITORS:
                await self.desktop.spawn([command, *menus.EDITORS[app]["remote"](host, cwd)])
        else:
            await self.desktop.spawn([command, cwd])

    # Publishing.

    def rows(self, now):
        rows = [self._row_of(session, now) for session in self.visible().values()]
        self._name_peers(rows)
        for conn in self.conns:
            for sid, entry in conn.demo.items():
                rows.append(demo_row(sid, entry))
        return model.ordered(rows)

    def _row_of(self, session, now):
        row = session.row(now, self.desktop.window_of(session.pid))
        if row["state"] == "working" and session.transcript:
            try:
                row["activity"] = int(os.stat(session.transcript).st_mtime * 1000)
            except OSError:
                pass
            self._with_progress(session, row)
        return row

    def _with_progress(self, session, row):
        """What the transcript says of a running turn, or of the jobs one ended to wait on: the
        agent's latest narration is the step it is on."""
        tail, turn = self.tails.get(session.id), session.turn
        if tail is None or turn is None or not (turn.open or (turn.outcome or {}).get("jobs")):
            return
        fields = tail.progress.view(jobs=not turn.open)
        step = fields.pop("step", "")
        row.update(fields)
        if turn.open and step:
            row["doing"] = row["reason"] = step

    def _name_peers(self, rows):
        """Tells each row which other sessions share its working tree."""
        by_root = {}
        for row in rows:
            session = self.sessions.get(row["id"])
            if session and session.root and not row.get("hidden"):
                by_root.setdefault(session.root, []).append(row)
        for members in by_root.values():
            for row in members:
                others = [other["name"] for other in members if other is not row]
                if others:
                    row["peers"] = others

    def state(self, rows):
        """The `state` message: the rows the bar shows, what ended, and how many are hidden."""
        recent = [{"id": r["id"], "agent": r.get("agent") or "claude", "name": r.get("name") or r.get("label") or "",
                   "summary": ((r.get("history") or [{}])[-1]).get("did") or "", "cwd": r.get("cwd") or "", "project": r.get("project") or "", "endedAt": r.get("endedAt") or 0,
                   "resume": resume_command(r.get("agent"), r["id"], r.get("cwd"), r.get("config_dir")),
                   "history": r.get("history") or []} for r in self.recent]
        shown = [row for row in rows if not row.get("hidden")]
        return {"type": "state", "sessions": shown, "recent": recent, "hidden": len(rows) - len(shown)}

    def _with_links(self, local, now):
        """The state with what the other hubs say: this host's order holds across them all, and
        each host's turns are announced by what this hub knew of that host."""
        rows, recent = list(local["sessions"]), list(local["recent"])
        due = []
        for host, link in self.links.items():
            # Copies: `pulse` must show as a change against the state last sent.
            copies = [dict(row) for row in link.rows]
            # A link that's down has no rows, and says nothing about what is known of that host.
            if link.status == "up":
                due.append(self.link_alerts[host].update(copies, now))
            rows += copies
            recent += link.recent
        recent.sort(key=lambda item: -item["endedAt"])
        return {**local, "sessions": model.ordered(rows), "recent": recent,
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
        # Saved before anyone hears of it: a client that saw a state can count on it surviving a restart.
        self._save()
        for conn in self.conns:
            if conn.subscriber and conn is not force_to and not conn.local and state != self._last:
                conn.send(state)
            elif conn.subscriber and conn is not force_to and conn.local and local != self._last_local:
                conn.send(local)
        self._last, self._last_local = state, local
        if force_to is not None:
            force_to.send(local if force_to.local else state)
        rows = {row["id"]: row for row in rows}
        for sid, conn in self.attached.items():
            session = self.sessions.get(sid)
            push = {"type": "row", "row": rows.get(sid)}
            if push != conn.pushed:
                conn.pushed = push
                conn.send(push)

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
        terminal or its Remote Control page. With neither, the popout says there is no way."""
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

    def _dismiss(self, sid, turn, viewer=True):
        """Puts away a finished turn or an open prompt: here, or on the host it belongs to. Naming
        a turn, only that one. `viewer` is you at this hub's bar, not another hub passing it on:
        only yours can be undone here."""
        row, session = self._row(sid), self.sessions.get(sid)
        if not (row and row["state"] in protocol.ATTENTION) or (turn is not None and row.get("turn") != turn):
            return
        host, own = links.split_id(sid)
        if host in self.links:
            self.links[host].send({"op": "dismiss", "session": own, "turn": turn or None})
        elif not (session and session.dismiss()):
            return
        if viewer:
            self.dismissals = [*self.dismissals, {"session": sid, "turn": row.get("turn"), "key": model.alert_key(row)}][-UNDO_MAX:]
        if host not in self.links:
            self.publish()

    def _undo(self):
        """Brings back the last dismissal at this bar that still stands. One whose session has
        started a new turn, or that is back already, is dropped along the way."""
        while self.dismissals:
            entry = self.dismissals.pop()
            sid, turn = entry["session"], entry["turn"]
            row = self._row(sid)
            if not row or row.get("turn") != turn or model.alert_key(row) == entry["key"]:
                continue
            host, own = links.split_id(sid)
            if host in self.links:
                self.link_alerts[host].expect(sid, entry["key"])
                self.links[host].send({"op": "undismiss", "session": own, "turn": turn or None})
                return
            if self._undismiss(sid, turn):
                return

    def _undismiss(self, sid, turn):
        """Brings back what was dismissed on this host's own session; false when it has moved on."""
        session = self.sessions.get(sid)
        if not (session and session.undismiss(turn)):
            return False
        self.alerts.expect(sid, model.alert_key(session.row(now_ms())))
        self.publish()
        return True

    async def _resume(self, sid):
        """Resumes an ended session in a new terminal, over ssh when it ended on another host."""
        host, own = links.split_id(sid)
        if host in self.links:
            item = next((r for r in self.links[host].recent if r["id"] == sid), None)
            if item is not None:
                await self._terminal(None, ["ssh", "-t", host, resume_command(item["agent"], own, item["cwd"])])
            return
        item = next((r for r in self.recent if r["id"] == sid), None)
        if item is not None:
            await self._terminal(item.get("cwd"), resume_argv(item.get("agent"), item["id"], item.get("config_dir")))

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
                message = None
                try:
                    parsed = json.loads(line)
                    # Read the request before validating: an op `validate` refuses must still
                    # answer the client waiting on it.
                    message = parsed if isinstance(parsed, dict) else None
                    await self._dispatch(conn, protocol.validate(parsed))
                except ValueError as error:
                    # Echo the request when the message had one: a client waiting on a reply to a
                    # write that failed must see the failure now, not sit until its timeout.
                    request = (message or {}).get("request")
                    conn.send({"type": "error", "error": str(error), **({"request": request} if isinstance(request, int) else {})})
                if conn.writer.is_closing():
                    break
        except (ConnectionError, asyncio.LimitOverrunError, ValueError):
            pass
        finally:
            self.conns.discard(conn)
            writer.close()
            self._forget_holds(conn)
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
        session.hidden = bool(message.get("hidden"))
        session.tmux = message.get("tmux") or ""
        name = message["name"]
        session.name = name.strip() if isinstance(name, str) else ""
        status = message["status"] if message["status"] in ("busy", "idle", "waiting") else "idle"
        if status == "waiting" and message["waitingFor"]:
            session.wait(label_line(message["waitingFor"]), now)
        else:
            session.observe(status, None, now)
        if status != "idle" and (session.turn is None or not session.turn.open):
            session.start_turn(now)
        self._recover(session)
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
        if message.get("hidden"):
            session.hidden = True
        if message.get("tmux"):
            session.tmux = message["tmux"]
        return session

    async def _turn_start(self, conn, message):
        session = self._own(conn, message)
        if session is None:
            return ""
        now = now_ms()
        if message.get("transcript"):
            session.transcript, session.leaf = message["transcript"], message.get("leaf")
        if message.get("peer"):
            session.start_aside(now)
        elif session.start_turn(now) is not None and session.id in self.tails:
            # The prompt reaches the transcript a moment later, and the last turn's trail is over now.
            self.tails[session.id].progress.new_turn()
        session.observe("busy", None, now)
        prompt = message.get("prompt") or ""
        if message.get("fromPerson", True) and prompt.strip() and not prompt.lstrip().startswith("<"):
            session.prompt = folded(prompt)[:PROMPT_MAX]
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
        outcome = model.ending(self._said(session, message.get("said")), message.get("tasks") or (),
                               message.get("pending"), message.get("error"), message.get("failure") or "")
        if session.aside is not None:
            reached = session.end_aside(outcome, now)
            session.observe("idle", None, now)
            self._release_all(session)
            worklog.append(self.log_file, {"at": now, "state": outcome["state"], "did": outcome["summary"],
                                           **self._log_fields(session), "peer": True,
                                           # What reached the row is a turn of its own.
                                           **({"turn": session.turn.n} if reached else {})})
            self.publish()
            return
        # An ending with no turn open to end: the agent carried on unannounced, as Claude does
        # when a background job reports back, or the hub restarted mid-turn.
        if session.turn is None or (not session.turn.open and session.turn.outcome is not None):
            session.start_turn(now)
        self._end_turn(session, outcome)
        session.observe("idle", None, now)
        self._release_all(session)
        self._spawn(self._ask_git(session))
        self.publish()

    async def _dispatch(self, conn, message):
        op = message["op"]
        if op == "subscribe":
            if message.get("version", protocol.VERSION) != protocol.VERSION:
                self._refuse(conn, message["version"])
                return
            conn.subscriber = True
            conn.local = bool(message.get("local"))
            # The last state sent is current: anything that changes it publishes.
            if self._last is None:
                self.publish(force_to=conn)
            else:
                conn.send(self._last_local if conn.local else self._last)
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
        elif op == "permission":
            self._permission(conn, message)
        elif op == "answer":
            self._answer(message["session"], message["ask"], message["allow"], viewer=not conn.local)
        elif op == "menu":
            # Not waited on: gh can take seconds, and this connection is the bar's.
            self._spawn(self._menu(conn, message))
        elif op == "run":
            await self._run(message)
        elif op == "git-facts":
            self._spawn(self._reply_facts(conn, message))
        elif op == "named":
            session = self._own(conn, message)
            if session is not None:
                session.name = (message["name"] or "").strip()
                self.publish()
        elif op == "session-start":
            session = self._own(conn, message)
            session.ending = False
            if message.get("transcript"):
                session.transcript = message["transcript"]
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
            self._dismiss(message["session"], message.get("turn"), viewer=not conn.local)
        elif op == "undo":
            self._undo()
        elif op == "undismiss":
            self._undismiss(message["session"], message.get("turn"))
        elif op == "seen":
            self.alerts.seen()
            for alerts in self.link_alerts.values():
                alerts.seen()
            # You are about to read their rows, and a checkout moves between turns too.
            for session in self.visible().values():
                self._spawn(self._ask_git(session))
            self.publish()
        elif op == "toggle":
            self._toggle()
        elif op == "resume":
            await self._resume(message["session"])
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
        session.wait(entry.get("waitingFor") or "", t)
    elif status == "busy":
        session.turn = model.Turn(n=1, started=t)
    elif entry.get("turnState"):
        session.turn = model.Turn(n=1, started=t, ended=t, outcome={
            **model.ending(entry.get("said") or "", error=entry["turnState"] == "failed"),
            **({"summary": entry["summary"]} if entry.get("summary") else {})})
    row = session.row(now_ms())
    if entry.get("doing"):
        row["doing"] = row["reason"] = entry["doing"]
    # What only a real session could say, for looking at the popout's pane. `id` 0 answers nothing.
    row.update({key: entry[key] for key in DEMO_DETAILS if key in entry})
    return row
