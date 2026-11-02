"""A session as the hub knows it, and the rules that move it: pure, no I/O, no clock of
its own (every change takes `now`), so the hub's behaviour is testable as data.

A turn opens on the agent's own word (pi's `turn-start`, Claude's UserPromptSubmit) and
closes on it (`turn-end`, Stop). The registry only stands in where that word never
comes: `busy` with no turn open starts one, `idle` with one open ends it as interrupted
(Esc fires no Stop). An ending that lands on a turn already closed that way still gets
read, unless a newer turn started meanwhile. A turn a restart caught open or unread comes
back `restored`, for the hub to read if its ending went unheard.
"""

from dataclasses import asdict, dataclass, field

from .protocol import ATTENTION, STATES

# Claude marks every open modal `waiting`; one it names this only shows something (the history view, /config).
SHOWING_DIALOGS = ("dialog open",)
# How a turn ended → the state it leaves the session in.
FINISHED = {"blocked": "needs-reply", "failed": "failed", "done": "done"}
# The endings a focus or `x` can put away; `asking` wants more than a look.
DISMISSABLE = tuple(FINISHED.values())
HISTORY = 3
# A dialog answered within this long never pulses, and Claude's hook has time to label it.
ASK_GRACE_MS = 1000
# A `done` pulses once: one breath of the bar's dot.
ONCE_MS = 1000
# Which field of a row says why it is in its state.
REASON_FIELD = {"asking": "waitingFor", "needs-reply": "ask", "failed": "summary", "done": "summary", "working": "doing"}


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
    # The turn number whose ending you put away.
    dismissed: int | None = None
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
        # The registry beat the hook to it: the hook's word adopts the turn it stood in for.
        if self.turn is not None and self.turn.open and self.turn.by == "registry":
            self.turn.by = by
            return None
        n = self.turn.n + 1 if self.turn else 1
        self.turn = Turn(n=n, started=now, by=by)
        return n

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
        `"interrupted"` when the registry stood in for a turn's start or end."""
        if registry:
            if (status, waiting_for, now) == self.registry_seen:
                return None
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
        if status == "busy" and (self.turn is None or not self.turn.open):
            return "started" if self.start_turn(now, by="registry") else None
        if status == "idle" and self.turn is not None and self.turn.open:
            self.end_turn(now, interrupted=True)
            return "interrupted"
        return None

    def wait(self, text, now):
        """The agent names the dialog it waits on."""
        self.dialog = text
        if self.status != "waiting":
            self.status, self.status_at = "waiting", now

    # What the bar shows.

    def state(self, now):
        turn = self.turn
        if self.status == "waiting":
            return "asking"
        if turn is not None and (turn.open or turn.reading or (turn.outcome or {}).get("jobs")):
            return "working"
        if turn is not None and turn.outcome and self.dismissed != turn.n:
            return FINISHED.get(turn.outcome["state"], "done")
        return "idle"

    def row(self, now, window=None):
        state = self.state(now)
        turn = self.turn
        outcome = (turn.outcome if turn else None) or {}
        if state == "asking":
            since = self.status_at
        elif turn is not None:
            since = turn.started if turn.open else turn.ended
        else:
            since = self.status_at
        doing = ""
        if state == "working":
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
        return row

    def dismiss(self):
        """Puts the finished turn away; false when there is none to put away."""
        if self.turn is None or self.turn.outcome is None or self.dismissed == self.turn.n:
            return False
        self.dismissed = self.turn.n
        return True


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

    def update(self, rows, now, focused=None, keep=()):
        """Sets each row's `pulse`; returns the ms until a pulse moves by itself, or None.
        A row gone is forgotten, unless its id is in `keep`: a session not listed just yet."""
        due = []
        for row in rows:
            rid, since = row["id"], row["since"]
            key = f"{row['state']}:{since}" if row["state"] in ATTENTION else None
            if key is None:
                self.known.pop(rid, None)
                self.pulsing.pop(rid, None)
            elif key != self.known.get(rid):
                if row["state"] == "asking" and not self.baseline and now - since < ASK_GRACE_MS:
                    due.append(since + ASK_GRACE_MS - now)
                    self.pulsing.pop(rid, None)
                    row["pulse"] = False
                    continue
                self.known[rid] = key
                self.pulsing.pop(rid, None)
                if not self.baseline:
                    self.pulsing[rid] = now + ONCE_MS if row["state"] == "done" else None
            # You are looking at it.
            if focused is not None and row["window"] == focused:
                self.pulsing.pop(rid, None)
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
