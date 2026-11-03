"""A session as the hub knows it, and the rules that move it: pure, no I/O, no clock of
its own (every change takes `now`), so the hub's behaviour is testable as data.

A turn opens on the agent's own word (pi's `turn-start`, Claude's UserPromptSubmit) and
closes on it (`turn-end`, Stop). The registry only stands in where that word never
comes: `busy` with no turn open starts one, once the agent has had `REGISTRY_GRACE_MS` to
speak if that would take an ending off the row, and `idle` with one open ends it as
interrupted (Esc fires no Stop). An ending that lands on a turn already closed that way
still gets read, unless a newer turn started meanwhile. A turn a restart caught open or
unread comes back `restored`, for the hub to read if its ending went unheard.

A peer's message wakes the session without you: that turn is an `aside`, which leaves the
standing turn alone, so what the row says of you and the session stays true.
"""

from dataclasses import asdict, dataclass, field

from .protocol import ATTENTION, STATES

# Claude marks every open modal `waiting`; one it names this only shows something (the history view, /config).
SHOWING_DIALOGS = ("dialog open",)
# How a turn ended → the state it leaves the session in.
FINISHED = {"blocked": "needs-reply", "failed": "failed", "done": "done"}
# The endings a focus can put away; `asking` wants more than a look, so only `x` hides it.
DISMISSABLE = tuple(FINISHED.values())
HISTORY = 3
# A dialog answered within this long never pulses, and Claude's hook has time to label it.
ASK_GRACE_MS = 1000
# A `done` pulses once: one breath of the bar's dot.
ONCE_MS = 1000
# The registry can say `busy` before the hook does, and only the hook can tell a peer's turn from yours.
REGISTRY_GRACE_MS = 2000
# Which field of a row says why it is in its state.
REASON_FIELD = {"asking": "waitingFor", "needs-reply": "ask", "failed": "summary", "done": "summary", "working": "doing"}
# What a row says of a held prompt.
PERMISSION = ("id", "tool", "about", "kind", "body", "complete")


@dataclass
class Turn:
    n: int
    started: int
    # "agent" for the agent's own word, "registry" for a turn the registry stood in for.
    by: str = "agent"
    ended: int | None = None
    # `judge.outcome`: state, ask, reply, summary, jobs, doing. None while unread, or interrupted.
    outcome: dict | None = None
    # The step the turn-start reading named.
    doing: str = ""
    reading: bool = False
    # Loaded open or mid-reading: a restart may have missed how it ended.
    restored: bool = False

    @property
    def open(self):
        return self.ended is None


@dataclass
class Session:
    id: str
    agent: str = "claude"
    pid: int | None = None
    cwd: str = ""
    config_dir: str | None = None
    # pi's session file and leaf entry, or Claude's transcript.
    transcript: str | None = None
    leaf: str | None = None
    # What the agent says it is doing: busy, idle or waiting, and since when.
    status: str = "idle"
    status_at: int = 0
    # The dialog it waits on, as its hook or pi named it.
    dialog: str = ""
    # The registry entry's own status, dialog and stamp, as last seen.
    registry_seen: tuple | None = None
    # The person's own name; `derived` is the registry's (`dir-NN`), which a label beats.
    name: str = ""
    derived: str = ""
    label: str = ""
    summary: str = ""
    tags: list = field(default_factory=list)
    calls: int = 0
    turn: Turn | None = None
    # A turn a peer's message woke it for, until it is read. Never saved.
    aside: Turn | None = None
    # When the registry said `busy` over a standing ending, with no word yet from the agent.
    busy_at: int | None = None
    # The turn a registry-started one replaced, which a peer's word gives back.
    replaced: Turn | None = None
    # The turn number whose ending you put away.
    dismissed: int | None = None
    # The open prompt you put away, which stays away for as long as it is that prompt.
    dismissed_prompt: tuple | None = None
    # The latest finished turns, newest last: `{at, state, did}`.
    history: list = field(default_factory=list)
    # When it was last known live, so one the registry hasn't caught up with is kept a while.
    seen: int = 0
    # The hook said the session ended: it lives only as long as the registry still lists it.
    ending: bool = False
    # The peers note a Claude session got last, which it is not told twice.
    told: str = ""
    # Spawned by an agent (`AGENT_HUB_HIDDEN=1`): tracked, but off the bar and never read.
    hidden: bool = False
    # Its tmux pane, and its Remote Control session: how another host can reach it.
    tmux: str = ""
    bridge: str = ""
    # What the person last asked it. Never saved: it stays in the transcript's care.
    prompt: str = ""
    # The prompts its hook holds open, oldest first, which is the one its dialog shows.
    holds: list = field(default_factory=list)
    # Its working tree, as git last said: the tree's root, branch, and files changed.
    root: str = ""
    branch: str = ""
    changed: int = 0
    # Whether git has been asked since this hub met it.
    git_asked: bool = False

    # Persistence.

    KEPT = ("id", "agent", "pid", "cwd", "config_dir", "transcript", "leaf", "label", "summary", "tags", "calls",
            "dismissed", "history", "hidden", "tmux")

    def saved(self):
        data = {key: getattr(self, key) for key in self.KEPT}
        if self.turn is not None:
            data["turn"] = {k: v for k, v in asdict(self.turn).items() if k not in ("doing", "restored")}
        return data

    @classmethod
    def load(cls, data, now):
        session = cls(**{key: data[key] for key in cls.KEPT if key in data}, seen=now)
        if isinstance(data.get("turn"), dict):
            turn = Turn(**data["turn"])
            turn.restored, turn.reading = turn.open or turn.reading, False
            session.turn = turn
        return session

    def identity(self):
        return {"label": self.label or None, "summary": self.summary or None, "tags": self.tags, "calls": self.calls}

    # Turns.

    def start_turn(self, now, by="agent"):
        """A turn starts; returns its number, or None when the open turn already is this one."""
        self.busy_at = None
        self.aside = None
        # The registry beat the hook to it: the hook's word adopts the turn it stood in for.
        if self.turn is not None and self.turn.open and self.turn.by == "registry":
            self.turn.by = by
            return None
        n = self.turn.n + 1 if self.turn else 1
        self.replaced = self.turn if by == "registry" else None
        self.turn = Turn(n=n, started=now, by=by)
        return n

    def standing(self):
        """Whether a closed turn still holds the row: an ending, or the reading or jobs of one."""
        turn = self.turn
        if turn is None or turn.open:
            return False
        return turn.reading or bool(turn.outcome and (self.dismissed != turn.n or turn.outcome.get("jobs")))

    def registry_turn(self, now):
        """Starts the turn the registry said `busy` for over a standing ending, once the agent
        has had its chance to speak; returns its number, or None when there is nothing due."""
        if self.busy_at is None or now - self.busy_at < REGISTRY_GRACE_MS:
            return None
        return self.start_turn(self.busy_at, by="registry")

    def start_aside(self, now):
        """A peer's message woke the session. One arriving mid-turn is part of that turn, unless
        only the registry had spoken for that turn, which then was this."""
        self.busy_at = None
        if self.turn is not None and self.turn.open:
            if self.turn.by != "registry":
                return
            self.turn = self.replaced
            # The registry's turn cancelled any reading of it, so none is coming.
            if self.turn is not None:
                self.turn.reading = False
        self.aside = Turn(n=0, started=now)

    def end_aside(self, now):
        self.aside.ended = self.aside.ended or now
        self.aside.reading = True

    def read_aside(self, aside, outcome, now):
        """How a peer's turn ended; None when it is no longer the one here. Returns whether it
        reached the row: only what wants you does, never over an ask already standing, and never
        over your own turn while it runs or is being read, since that reading would be dropped."""
        if self.aside is not aside:
            return None
        self.aside = None
        state = FINISHED.get(outcome["state"], "done")
        standing = self.turn is not None and self.dismissed != self.turn.n and (self.turn.outcome or {}).get("state") == "blocked"
        if state == "done" or standing or (self.turn is not None and (self.turn.open or self.turn.reading)):
            return False
        self.turn = Turn(n=self.turn.n + 1 if self.turn else 1, started=aside.started, ended=aside.ended, outcome=outcome)
        self.history = (self.history + [{"at": aside.ended, "state": state, "did": outcome.get("summary") or ""}])[-HISTORY:]
        return True

    def aside_running(self):
        return self.aside is not None and (self.aside.open or self.aside.reading)

    def end_turn(self, now, interrupted=False):
        """A turn ends; returns the number to read, or None when there is nothing to read."""
        turn = self.turn
        if turn is None:
            return None
        if turn.open:
            turn.ended, turn.doing = now, ""
            return None if interrupted else turn.n
        # An ending for a turn the registry closed as interrupted is still that turn's.
        return None if interrupted or turn.outcome is not None else turn.n

    def reading(self, n, on):
        if self.turn is not None and self.turn.n == n:
            self.turn.reading = on

    def read(self, n, outcome, now):
        """Takes how turn `n` ended; false when a newer turn has the last word."""
        turn = self.turn
        if turn is None or turn.n != n or turn.open:
            return False
        turn.outcome, turn.reading = outcome, False
        state = FINISHED.get(outcome["state"], "done")
        self.history = (self.history + [{"at": turn.ended, "state": state, "did": outcome.get("summary") or ""}])[-HISTORY:]
        return True

    def step(self, doing):
        """The step a turn-start reading named, for the turn still running."""
        if self.turn is not None and self.turn.open:
            self.turn.doing = doing

    # The agent's own status.

    def observe(self, status, waiting_for, now, registry=False):
        """What the agent says it is doing, or its registry entry: only a move of the
        entry counts, since the hooks may already have said more, and for an entry `now`
        is its own stamp, which every status change renews. Returns `"started"` or
        `"interrupted"` when the registry stood in for a turn's start or end, and `"busy"`
        when a `registry_turn` will be due unless the agent speaks first."""
        if registry:
            if (status, waiting_for, now) == self.registry_seen:
                return None
            # Still waiting, under a new stamp: one prompt closed and another opened between looks.
            if status == "waiting" and self.registry_seen and self.registry_seen[0] == "waiting":
                self.dismissed_prompt = None
            self.registry_seen = (status, waiting_for, now)
        if status == "waiting" and not self.dialog and waiting_for in SHOWING_DIALOGS:
            # A modal that only shows something leaves the session as it was.
            return None
        if status != self.status:
            self.status_at = now
            # The hook can beat the registry to a dialog, so only a move away from one drops its label.
            if status != "waiting":
                self.dialog = ""
        self.status = status
        if status == "waiting" and waiting_for and not self.dialog:
            self.dialog = waiting_for
        if not registry:
            return None
        if status == "busy" and (self.turn is None or not self.turn.open) and not self.aside_running():
            if self.standing():
                self.busy_at = now
                return "busy"
            return "started" if self.start_turn(now, by="registry") else None
        if status == "idle":
            self.busy_at = None
            # A Stop may still come for it, as for a turn.
            if self.aside is not None and self.aside.open:
                self.aside.ended = now
            if self.turn is not None and self.turn.open:
                self.end_turn(now, interrupted=True)
                return "interrupted"
        return None

    def wait(self, text, now):
        """The agent names the dialog it waits on."""
        self.dialog = text
        if self.status != "waiting":
            self.status, self.status_at = "waiting", now

    # Prompts a hook holds open.

    def hold(self, hold_id, ask, text, now):
        """A hook holds a prompt open. The registry stamp it opened under, when it got there
        first, tells it from the next prompt under a new stamp."""
        seen = self.registry_seen
        stamp = seen[2] if seen and seen[0] == "waiting" and not self.holds else None
        self.holds.append({**ask, "id": hold_id, "text": text, "opened": now, "stamp": stamp})
        self.wait(self.holds[0]["text"], now)

    def unhold(self, hold):
        """A held prompt is settled: the next one is what its dialog shows now."""
        self.holds.remove(hold)
        if self.holds:
            self.dialog = self.holds[0]["text"]

    def closed_holds(self):
        """The holds the registry says are over. Claude leaves a hook running when you answer
        its dialog in the terminal, so this is how the hub hears of it. A status older than the
        prompt says nothing about it, and a new `waiting` stamp means the prompt shown closed."""
        seen = self.registry_seen
        if not (self.holds and seen):
            return []
        status, _, stamp = seen
        if status != "waiting":
            return [hold for hold in self.holds if stamp >= hold["opened"]]
        first = self.holds[0]
        if first["stamp"] is None:
            first["stamp"] = stamp
        if first["stamp"] == stamp:
            return []
        if len(self.holds) > 1:
            self.holds[1]["stamp"] = stamp
        return [first]

    # What the bar shows.

    def state(self, now):
        turn = self.turn
        if self.status == "waiting" and self.open_prompt() != self.dismissed_prompt:
            return "asking"
        if turn is not None and (turn.open or turn.reading or (turn.outcome or {}).get("jobs")):
            return "working"
        if turn is not None and turn.outcome and self.dismissed != turn.n:
            return FINISHED.get(turn.outcome["state"], "done")
        return "working" if self.aside_running() else "idle"

    def row(self, now, window=None):
        state = self.state(now)
        turn = self.turn
        outcome = (turn.outcome if turn else None) or {}
        # Working only for a peer: no turn of its own is running or being read.
        aside = state == "working" and not (turn is not None and (turn.open or turn.reading or outcome.get("jobs")))
        if state == "asking":
            since = self.status_at
        elif aside:
            since = self.aside.started
        elif turn is not None:
            since = turn.started if turn.open else turn.ended
        else:
            since = self.status_at
        doing = ""
        if aside:
            doing = "answering another session"
        elif state == "working":
            if turn.open:
                doing = turn.doing
            elif turn.reading:
                doing = "reading the turn"
            else:
                jobs = outcome["jobs"]
                doing = outcome.get("doing") or f"waiting on {jobs} background job" + ("s" if jobs > 1 else "")
        row = {
            "id": self.id,
            "agent": self.agent,
            "name": self.name or self.label or self.derived or self.cwd.rstrip("/").rsplit("/", 1)[-1] or self.agent,
            "label": self.label,
            "cwd": self.cwd,
            "pid": self.pid,
            "state": state,
            "since": since,
            "doing": doing,
            "summary": outcome.get("summary") or self.summary,
            "waitingFor": self.dialog if state == "asking" else "",
            "ask": outcome.get("ask") or "" if state == "needs-reply" else "",
            "reply": outcome.get("reply") or "" if state == "needs-reply" else "",
            "window": window,
            "history": list(self.history),
        }
        field_ = REASON_FIELD.get(state)
        row["reason"] = (row[field_] or "").strip() if field_ else ""
        if self.hidden:
            row["hidden"] = True
        if turn is not None:
            row["turn"] = turn.n
        if self.tmux:
            row["tmux"] = self.tmux
        if self.bridge:
            row["bridge"] = self.bridge
        details = {"prompt": self.prompt, "branch": self.branch, "changed": self.changed,
                   "said": outcome.get("said") if state == "needs-reply" else "",
                   "askKind": outcome.get("kind") if state == "needs-reply" else "",
                   "jobs": outcome.get("tasks") if state == "working" and not aside and not turn.open else None}
        row.update({key: value for key, value in details.items() if value})
        if state == "asking" and self.holds:
            row["permission"] = {key: self.holds[0][key] for key in PERMISSION}
        return row

    def open_prompt(self):
        """What tells this prompt from the next one, or None when none is open."""
        return (self.status_at, self.dialog) if self.status == "waiting" else None

    def dismiss(self):
        """Puts the open prompt away, or else the finished turn; false when there is neither."""
        prompt = self.open_prompt()
        if prompt is not None and prompt != self.dismissed_prompt:
            self.dismissed_prompt = prompt
            return True
        if self.turn is None or self.turn.outcome is None or self.dismissed == self.turn.n:
            return False
        self.dismissed = self.turn.n
        return True

    def undismiss(self, turn):
        """Brings back what `dismiss` put away, last in first out; false when it has moved on.
        `turn` is the one the dismissal named, so a newer ending stays as it is."""
        if self.dismissed_prompt is not None and self.dismissed_prompt == self.open_prompt():
            self.dismissed_prompt = None
            return True
        if self.turn is None or self.turn.n != turn or self.dismissed != turn:
            return False
        self.dismissed = None
        return True


def alert_key(row):
    """What a row has to announce, or None when it doesn't want you."""
    return f"{row['state']}:{row['since']}" if row["state"] in ATTENTION else None


class Alerts:
    """Which of a host's rows pulse. A row pulses when it comes to want you with an ending
    not yet known: `known` (row id → `state:since`) outlives a restart or a dropped link, so
    a turn already known stays quiet and one that ended meanwhile pulses. Without a `known`,
    at first sight of a host, whatever is there counts as known."""

    def __init__(self, known=None):
        self.baseline = known is None
        self.known = dict(known or {})
        # Row id → when its pulse stops; None for when you have looked.
        self.pulsing = {}
        # Rows you have been to since they came to want you.
        self.opened = set()
        # Row id → the key it is coming back with: you brought it back, so it is no news.
        self.returning = {}

    def expect(self, rid, key):
        """`rid` will come back as `key`, which you asked for: it doesn't pulse."""
        self.returning[rid] = key

    def update(self, rows, now, focused=None, keep=()):
        """Sets each row's `pulse`; returns the ms until a pulse moves by itself, or None.
        A row gone is forgotten, unless its id is in `keep`: a session not listed just yet."""
        due = []
        for row in rows:
            rid, since = row["id"], row["since"]
            key = alert_key(row)
            if key is None:
                self.known.pop(rid, None)
                self.pulsing.pop(rid, None)
                self.opened.discard(rid)
            elif key != self.known.get(rid):
                if row["state"] == "asking" and not self.baseline and now - since < ASK_GRACE_MS:
                    due.append(since + ASK_GRACE_MS - now)
                    self.pulsing.pop(rid, None)
                    row["pulse"] = False
                    continue
                self.known[rid] = key
                self.pulsing.pop(rid, None)
                self.opened.discard(rid)
                if self.returning.pop(rid, None) == key:
                    self.opened.add(rid)
                elif not self.baseline:
                    self.pulsing[rid] = now + ONCE_MS if row["state"] == "done" else None
            # You are looking at it.
            if focused is not None and row["window"] == focused:
                self.pulsing.pop(rid, None)
                if key is not None:
                    self.opened.add(rid)
            until = self.pulsing.get(rid)
            if until is not None:
                if now >= until:
                    del self.pulsing[rid]
                else:
                    due.append(until - now)
            row["pulse"] = rid in self.pulsing
        shown = {row["id"] for row in rows} | set(keep)
        self.known = {rid: key for rid, key in self.known.items() if rid in shown}
        self.pulsing = {rid: until for rid, until in self.pulsing.items() if rid in shown}
        self.opened &= shown
        self.returning = {rid: key for rid, key in self.returning.items() if rid in shown}
        self.baseline = False
        return min(due) if due else None

    def seen(self):
        """The popout opened: nothing pulses until something new wants you."""
        self.pulsing.clear()


def ordered(rows):
    """The one order: the bar lists it, and focus-next walks it. What wants you,
    longest-waiting first; the rest, latest first."""
    rank = {state: i for i, state in enumerate(STATES)}
    return sorted(rows, key=lambda r: (rank[r["state"]], r["since"] if r["state"] in ATTENTION else -r["since"]))
