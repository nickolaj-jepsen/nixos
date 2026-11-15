"""Every message on the hub's socket, defined once; the hub validates what it takes against it.

Line-delimited JSON. A message to the hub names an `op`; one from it names a `type`. Nothing is
answered: the hub sends its `state` to subscribers, and everything else is fire-and-forget. A
session is always named by its id string, `session`. Fields may be added freely.

A type is a string (`str`, `int`, `bool`, `any`, `null` or a literal word, joined with `|`), a
list of one type or a dict of fields; a field whose key ends in `?` may
be left out.
"""


# The order the bar lists states in; the first three want you.
STATES = ("asking", "failed", "done", "working", "idle")
ATTENTION = STATES[:3]

ROW = {
    "id": "str",
    "agent": "str",
    "name": "str",
    "cwd": "str",
    "pid": "int|null",
    "state": "|".join(STATES),
    # Why it is in its state: the dialog it waits on, the error that failed it, the first sentence of its last words.
    "reason": "str",
    "since": "int",
    "doing": "str",
    "waitingFor": "str",
    "window": "int|null",
    # The bar's dot pulses: this came to want you and you haven't looked yet.
    "pulse?": "bool",
    # An agent-spawned session: tracked, but the bar never shows it.
    "hidden?": "bool",
    # The turn its ending belongs to, so a late dismissal can't put away a newer one.
    "turn?": "int",
    # Set by the viewer on a row from another host, where its id is `host:session`.
    "host?": "str",
    # How to reach it from elsewhere: its tmux pane, and its Remote Control session.
    "tmux?": "str",
    "bridge?": "str",
    # The repository, the same from any of its worktrees; the directory's own name outside git.
    "project?": "str",
}

# A link to another host's hub: `up`, or why it isn't.
LINK = {"host": "str", "status": "str"}

# A background task still in flight when a Claude turn stopped.
TASK = {"type": "str", "description?": "str|null"}

# What Claude's hooks say of themselves, for the session they name.
WHO = {"session": "str", "pid?": "int|null", "cwd?": "str|null", "hidden?": "bool", "tmux?": "str|null",
       "transcript?": "str|null"}

OPS = {
    # The bar and the CLI. `local`: this host's own sessions, leaving out what it links in.
    "subscribe": {"local?": "bool"},
    "focus": {"session": "str"},
    "focus-next": {},
    "dismiss": {"session": "str", "turn?": "int"},
    # Brings back the last thing dismissed at this bar.
    "undo": {},
    # The popout opened: you have seen what pulses.
    "seen": {},
    "toggle": {},
    "demo": {"sessions": ["any"]},
    # Claude's hooks, all fire-and-forget. `peer`: another session's message woke it, so what the row stands on stays.
    "turn-start": {"peer?": "bool", **WHO},
    # `said` and `tasks` are the agent's own word. `failure` is why the turn died, which needs no reading.
    "turn-end": {"said?": "str|null", "tasks?": [TASK], "failure?": "str", **WHO},
}

TYPES = {
    # `hidden` counts the agent-spawned sessions left out of `sessions`.
    "state": {"sessions": [ROW], "hidden?": "int", "links?": [LINK]},
    # `attach` says it is alive between states.
    "beat": {},
    "error": {"error": "str"},
}

BASE = ("str", "int", "bool", "any", "null")


def _check(value, spec, where):
    if isinstance(spec, list):
        if not isinstance(value, list):
            raise ValueError(f"{where} must be a list")
        for i, item in enumerate(value):
            _check(item, spec[0], f"{where}[{i}]")
    elif isinstance(spec, dict):
        if not isinstance(value, dict):
            raise ValueError(f"{where} must be an object")
        for key, field in spec.items():
            name = key.rstrip("?")
            if name in value:
                _check(value[name], field, f"{where}.{name}")
            elif not key.endswith("?"):
                raise ValueError(f"{where}.{name} is missing")
    else:
        kinds = spec.split("|")
        ok = any(
            kind == "any"
            or (kind == "null" and value is None)
            or (kind == "str" and isinstance(value, str))
            or (kind == "bool" and isinstance(value, bool))
            or (kind == "int" and isinstance(value, int) and not isinstance(value, bool))
            or (kind not in BASE and value == kind)
            for kind in kinds
        )
        if not ok:
            raise ValueError(f"{where} must be {spec}")


def validate(message):
    """`message` as an op the hub takes; ValueError names the first field that is off."""
    if not isinstance(message, dict):
        raise ValueError("a message must be an object")
    op = message.get("op")
    if op not in OPS:
        raise ValueError(f"unknown op {op!r}")
    _check(message, OPS[op], op)
    return message
