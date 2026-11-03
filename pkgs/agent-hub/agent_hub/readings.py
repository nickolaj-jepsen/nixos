"""When the hub asks a model about a session, and who answers: pi itself over its
connection, or `claude -p` as the session's own profile.

Two readings per turn at most: one as it starts (what the work is called, the step it is
on) and one as it ends (how it ended). One runs at a time per session; a new turn cancels
the reading of the last one's ending, and `Session.read` drops one that lands late anyway.
"""

import asyncio
import os

from . import claude, judge, pi, worklog
from .common import now_ms, shown_block, socket_path

# A runaway guard rather than a budget: a reading costs a fraction of a cent.
CALL_CAP = 500
# A paste and the follow-up that corrects it are one turn's naming, not two.
MIN_CALL_GAP_MS = 10_000
# A Claude Code reading is a `claude -p` process: once named, a session is renamed this seldom.
CLAUDE_RELABEL_MS = 10 * 60_000
# A dead model should stop being asked, not be asked again every turn.
MAX_FAILURES = 3
TIMEOUT = 60
OUTPUT_BYTES = 2000


def output_tail(path):
    """The end of what a background job has written, as text that can be shown, or ""."""
    if not path:
        return ""
    try:
        with open(path, "rb") as output:
            output.seek(0, os.SEEK_END)
            output.seek(max(0, output.tell() - OUTPUT_BYTES))
            return shown_block(output.read().decode(errors="replace"), OUTPUT_BYTES)[0]
    except OSError:
        return ""


def digest(session, prompt=None):
    """The session's digest from its transcript, or None without a readable one."""
    if not session.transcript:
        return None
    if session.agent == "pi":
        return pi.digest(session.transcript, session.leaf, session.cwd, prompt)
    return claude.digest(session.transcript, session.cwd, prompt)


class Readings:
    def __init__(self, hub, claude_exe):
        self.hub = hub
        self.claude = claude_exe
        # Session id → its lock, failures in a row, last call, and the ending being read.
        self.locks = {}
        self.failures = {}
        self.last = {}
        self.settling = {}
        # Session id → the peer's turn being read, which must not cancel the session's own.
        self.asides = {}

    def forget(self, sid):
        for table in (self.locks, self.failures, self.last):
            table.pop(sid, None)
        self.cancel(sid)

    def stopped(self, session):
        """Why this session's model is no longer asked: `failing`, `capped`, or "" while it is."""
        if self.failures.get(session.id, 0) >= MAX_FAILURES:
            return "failing"
        return "capped" if session.calls >= CALL_CAP else ""

    def backend(self, session):
        """("agent", conn) for an attached pi, ("claude", config dir) for Claude, else None.
        A hidden session is never read."""
        if session.hidden:
            return None
        conn = self.hub.attached.get(session.id)
        if conn is not None:
            return ("agent", conn)
        if session.agent == "claude" and self.claude:
            return ("claude", session.config_dir)
        return None

    def _lock(self, sid):
        return self.locks.setdefault(sid, asyncio.Lock())

    # The turn-start reading.

    async def label(self, session, prompt=None, manual=False):
        """What the work is called and the step it is on, unless one was asked too lately."""
        backend = self.backend(session)
        if backend is None:
            if manual:
                self.hub.notice(session.id, "identity: no model to ask")
            return
        if not manual:
            gap = CLAUDE_RELABEL_MS if backend[0] == "claude" and session.label else MIN_CALL_GAP_MS
            if now_ms() - self.last.get(session.id, 0) < gap:
                return
        lock = self._lock(session.id)
        if lock.locked():
            return
        async with lock:
            self.last[session.id] = now_ms()
            found = await asyncio.to_thread(digest, session, prompt)
            if found is None:
                return
            await self.hub.git.context(session.cwd, found)
            fields = await self._call(session, "start", found, manual)
            if fields is not None and "doing" in fields:
                session.step(fields["doing"])
            self.hub.publish()

    # The turn-end reading.

    def settle(self, session, n, ending):
        """Reads how turn `n` ended; a newer turn's start cancels it. `ending` is what the
        agent said of it (`turn-end`'s `said`, `tasks`, `pending`, `error`, `failure`)."""
        self.cancel(session.id)
        session.reading(n, True)
        task = asyncio.create_task(self._settle(session, n, ending))
        self.settling[session.id] = task
        task.add_done_callback(lambda done: self.settling.pop(session.id, None) if self.settling.get(session.id) is done else None)

    def settle_aside(self, session, ending):
        """Reads how a peer's turn ended, beside any reading of the session's own turn."""
        aside = session.aside
        previous = self.asides.get(session.id)
        if previous is not None:
            previous.cancel()
        task = asyncio.create_task(self._settle_aside(session, aside, ending))
        self.asides[session.id] = task
        task.add_done_callback(lambda done: self.asides.pop(session.id, None) if self.asides.get(session.id) is done else None)

    def cancel(self, sid):
        for table in (self.settling, self.asides):
            task = table.pop(sid, None)
            if task is not None:
                task.cancel()

    async def _settle(self, session, n, ending):
        try:
            if ending.get("failure"):
                self.hub.turn_read(session, n, judge.died(ending["failure"]))
                return
            found = await asyncio.to_thread(digest, session)
            if found is None and not ending.get("said") and not ending.get("error"):
                self.hub.turn_read(session, n, None)
                return
            found = judge.with_ending(found or {}, ending)
            await self.hub.git.context(session.cwd, found)
            guess = judge.heuristic(found)
            fields = None
            # Agent work in flight settles it unread, unless the closing words ask something.
            if self.backend(session) and (guess["ask"] or not found["agents"]):
                async with self._lock(session.id):
                    fields = await self._call(session, "settle", found)
            self.hub.turn_read(session, n, judge.outcome(fields or {}, guess, found))
        except asyncio.CancelledError:
            session.reading(n, False)
            raise

    async def _settle_aside(self, session, aside, ending):
        if ending.get("failure"):
            self.hub.aside_read(session, aside, judge.died(ending["failure"]))
            return
        found = await asyncio.to_thread(digest, session)
        found = {**judge.with_ending(found or {}, ending), "peer": True}
        guess = judge.heuristic(found)
        fields = None
        # Only an ask can reach the row, so nothing else is worth a call.
        if guess["ask"] and self.backend(session):
            async with self._lock(session.id):
                fields = await self._call(session, "settle", found, identity=False)
        self.hub.aside_read(session, aside, judge.outcome(fields or {}, guess, found))

    # A long command.

    async def estimate(self, session, call, log_file):
        """Reads how long a long command has left, onto `call`, for its row and the work log."""
        backend = self.backend(session)
        if backend is None or self.failures.get(session.id, 0) >= MAX_FAILURES or session.calls >= CALL_CAP:
            return
        session.calls += 1
        past = await asyncio.to_thread(worklog.past_minutes, log_file, call["line"])
        output = await asyncio.to_thread(output_tail, call.get("output"))
        prompt = judge.estimate_prompt(call["line"], (now_ms() - call["at"]) // 60_000, past, output)
        if backend[0] == "agent":
            text = await self._ask_agent(backend[1], prompt, "settle", judge.ESTIMATE_SYSTEM, "job estimate", judge.ESTIMATE_MAX_TOKENS)
        else:
            text = await self._ask_claude(backend[1], prompt, judge.ESTIMATE_SYSTEM)
        found = judge.parse_estimate(text) if text else None
        if found:
            call["estimate"] = {**found, "at": now_ms(), "after": now_ms() - call["at"]}
            self.hub.publish()

    # The call.

    async def _call(self, session, moment, found, manual=False, identity=True):
        """One reading through the session's backend; the fields it gave, or None. `identity`
        false keeps what the session is called out of it, as for a peer's turn."""
        backend = self.backend(session)
        if backend is None:
            return None
        failures = self.failures.get(session.id, 0)
        if failures >= MAX_FAILURES or session.calls >= CALL_CAP:
            if manual:
                self.hub.notice(session.id, "identity: the label model keeps failing, staying quiet"
                                if failures >= MAX_FAILURES else f"identity: label call cap ({CALL_CAP}) reached")
            return None
        prompt = judge.render(found, session.identity(), moment == "settle")
        # Counted on any outcome, so a model that keeps failing still meets the cap.
        session.calls += 1
        if backend[0] == "agent":
            text = await self._ask_agent(backend[1], prompt, moment)
        else:
            text = await self._ask_claude(backend[1], prompt)
        fields = judge.parse(text) if text else {}
        if not fields:
            self.failures[session.id] = failures + 1
            if manual:
                self.hub.notice(session.id, "identity: relabel failed")
            return None
        self.failures[session.id] = 0
        if not identity:
            return fields
        label = judge.clean_label(fields["label"]) if fields.get("label") else ""
        if label:
            session.label = label
        if fields.get("summary"):
            session.summary = fields["summary"]
        if "tags" in fields:
            session.tags = fields["tags"]
        return fields

    async def _ask_agent(self, conn, prompt, moment, system=judge.SYSTEM, source=None, max_tokens=judge.MAX_TOKENS):
        conn.next_call += 1
        request = conn.next_call
        future = asyncio.get_running_loop().create_future()
        conn.calls[request] = future
        # The settle half runs once per turn, so pi's /cost shows it on its own.
        conn.send({"type": "judge", "request": request, "system": system, "prompt": prompt, "maxTokens": max_tokens,
                   "source": source or ("session ask" if moment == "settle" else "session label")})
        try:
            return await asyncio.wait_for(future, TIMEOUT)
        except asyncio.TimeoutError:
            return None
        except asyncio.CancelledError:
            conn.send({"type": "cancel", "request": request})
            raise
        finally:
            conn.calls.pop(request, None)

    async def _ask_claude(self, config_dir, prompt, system=judge.SYSTEM):
        env = dict(os.environ)
        # Unset means the default profile; naming ~/.claude instead would move its config file.
        if config_dir:
            env["CLAUDE_CONFIG_DIR"] = config_dir
        proc = None
        try:
            proc = await asyncio.create_subprocess_exec(
                self.claude, *claude.JUDGE_ARGS, "--system-prompt", system,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
                env=env, cwd=str(socket_path().parent),
            )
            out, _ = await asyncio.wait_for(proc.communicate(prompt.encode()), TIMEOUT)
        except (OSError, asyncio.TimeoutError, asyncio.CancelledError) as error:
            if proc and proc.returncode is None:
                proc.kill()
            if isinstance(error, asyncio.CancelledError):
                raise
            return None
        return out.decode(errors="replace") if proc.returncode == 0 else None
