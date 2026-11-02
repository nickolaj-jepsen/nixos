"""Every message on the hub's socket, defined once: the hub validates against it, and pi's
build generates its TypeScript types from it (`python3 protocol.py --typescript`), so this
module imports nothing but the standard library.

Line-delimited JSON. A message to the hub names an `op`; one from it names a `type`. An op
that carries `request` is answered with a `reply` of the same number. A session is always
named by its id string, `session`. Fields may be added freely; a client that has to read
a change of meaning or shape bumps `VERSION`, and the hub answers a connection that says
another one with `refused` and closes it; the client says so and stops reconnecting.

A type is a string (`str`, `int`, `bool`, `any`, `null` or a literal word, joined with `|`), a
list of one type, a dict of fields, or `Nullable(dict)`; a field whose key ends in `?` may
be left out.
"""

import json
import sys

VERSION = 3


class Nullable:
    def __init__(self, spec):
        self.spec = spec


# The order the bar lists states in; the first four want you.
STATES = ("asking", "needs-reply", "failed", "done", "working", "idle")
ATTENTION = STATES[:4]

IDENTITY = {"label?": "str|null", "summary?": "str|null", "tags?": ["str"], "calls?": "int|null"}

TURN = {"at": "int", "state": "str", "did": "str"}

# What a permission prompt asks, in full. `complete` is false when `body` had to be cut,
# and then nothing may allow it from the bar: you can't approve what you can't read.
ASK = {"tool": "str", "about": "str", "kind": "command|diff|text", "body": "str", "complete": "bool"}

ROW = {
    "id": "str",
    "agent": "str",
    "name": "str",
    "label": "str",
    "cwd": "str",
    "pid": "int|null",
    "state": "|".join(STATES),
    "reason": "str",
    "since": "int",
    "doing": "str",
    "summary": "str",
    "waitingFor": "str",
    "ask": "str",
    "reply": "str",
    "window": "int|null",
    # The latest finished turns, newest last.
    "history": [TURN],
    # The bar's dot pulses: this came to want you and you haven't looked yet.
    "pulse?": "bool",
    # An agent-spawned session: its own TUI still gets its row, the bar never does.
    "hidden?": "bool",
    # The turn its ending belongs to, so a late dismissal can't put away a newer one.
    "turn?": "int",
    # Set by the viewer on a row from another host, where its id is `host:session`.
    "host?": "str",
    # How to reach it from elsewhere: its tmux pane, and its Remote Control session.
    "tmux?": "str",
    "bridge?": "str",
    # What you last asked it, kept only while the hub runs.
    "prompt?": "str",
    # The closing words of a turn that needs a reply, as the agent wrote them.
    "said?": "str",
    # The prompt a hook is holding open, which `answer` can settle by this `id`.
    "permission?": {"id": "int", **ASK},
    "branch?": "str",
    # How many files have uncommitted changes.
    "changed?": "int",
    # The other sessions in the same working tree, by name.
    "peers?": ["str"],
    # While working, when its transcript last moved.
    "activity?": "int",
    # The background work a finished turn still waits on.
    "jobs?": ["str"],
}

RECENT = {
    "id": "str",
    "agent": "str",
    "label": "str",
    "summary": "str",
    "cwd": "str",
    "endedAt": "int",
    "resume": "str",
    "history": [TURN],
    "host?": "str",
}

# A link to another host's hub: `up`, or why it isn't.
LINK = {"host": "str", "status": "str"}

# Who reads a turn: pi's session file and leaf entry, or Claude's transcript.
TRANSCRIPT = {"transcript?": "str|null", "leaf?": "str|null"}

# A background task still in flight when a Claude turn stopped.
TASK = {"type": "str", "description?": "str|null"}

OPS = {
    # The bar and the CLI.
    # `local`: this host's own sessions, leaving out what it links in.
    "subscribe": {"version?": "int", "local?": "bool"},
    "focus": {"session": "str"},
    "focus-next": {},
    "dismiss": {"session": "str", "turn?": "int"},
    # Brings back the last thing dismissed at this bar.
    "undo": {},
    # Brings back one session's, as another hub's `undo` asks.
    "undismiss": {"session": "str", "turn?": "int"},
    "wrong": {"session": "str"},
    # The popout opened: you have seen what pulses.
    "seen": {},
    "toggle": {},
    "resume": {"session": "str"},
    # Settles the prompt `ask` names, and only that one.
    "answer": {"session": "str", "ask": "int", "allow": "bool"},
    # Asks for a row's folder or git menu, answered with `menu`, twice when a lookup follows.
    "menu": {"request": "int", "session": "str", "which": "folder|git"},
    # Does what a menu row says.
    "run": {"session": "str", "kind": "url|copy|app", "value": "str"},
    # What this host's git says of a session, for a viewer's git menu; answered in `reply.facts`.
    "git-facts": {"request": "int", "session": "str"},
    "demo": {"sessions": ["any"]},
    # pi, for the life of its connection; ops after `attach` name no session.
    "attach": {
        "version": "int",
        "session": "str",
        "pid": "int",
        "cwd": "str",
        "status": "str",
        "since": "int",
        "waitingFor": "str|null",
        "name": "str|null",
        "record": IDENTITY,
        "hidden?": "bool",
        "tmux?": "str|null",
        **TRANSCRIPT,
    },
    # pi's own, or a Claude hook's for the session it names.
    "dialog": {"session?": "str", "text": "str|null"},
    # Claude's PermissionRequest hook, held open until `reply` says what became of the prompt.
    "permission": {"request": "int", "session": "str", "text": "str", "ask": ASK, "pid?": "int|null", "cwd?": "str|null",
                   "configDir?": "str|null", "hidden?": "bool", "tmux?": "str|null"},
    "named": {"name": "str|null"},
    # No text: the call failed.
    "judged": {"request": "int", "text?": "str"},
    # Both agents; Claude's hooks name their session and say who runs it.
    "session-start": {"session": "str", "pid?": "int|null", "cwd?": "str|null", "configDir?": "str|null", "hidden?": "bool",
                      "tmux?": "str|null"},
    "session-end": {"session": "str"},
    "turn-start": {"request?": "int", "session?": "str", "prompt?": "str|null", "fromPerson?": "bool",
                   "worktreeTool?": "bool", "pid?": "int|null", "cwd?": "str|null", "configDir?": "str|null",
                   "hidden?": "bool", "tmux?": "str|null", **TRANSCRIPT},
    # `said` and `tasks` are the agent's own word, which a transcript can lag behind.
    # `failure` is why the turn died, which needs no reading.
    "turn-end": {"session?": "str", "pending?": "int", "error?": "bool", "said?": "str|null", "tasks?": [TASK],
                 "failure?": "str", "pid?": "int|null", "cwd?": "str|null", "configDir?": "str|null", "hidden?": "bool",
                 "tmux?": "str|null", **TRANSCRIPT},
    "relabel": {},
}

TYPES = {
    # `hidden` counts the agent-spawned sessions left out of `sessions`.
    "state": {"sessions": [ROW], "recent": [RECENT], "hidden?": "int", "links?": [LINK]},
    # `attach` says it is alive between states.
    "beat": {},
    "row": {"row": Nullable(ROW), "identity": IDENTITY},
    "judge": {"request": "int", "system": "str", "prompt": "str", "maxTokens": "int", "source": "str"},
    "cancel": {"request": "int"},
    # `decision` answers a held `permission`; without one the prompt closed some other way.
    "reply": {"request": "int", "peers?": "str", "decision?": "allow|deny", "facts?": "any"},
    "menu": {"request": "int", "menu": "any"},
    "notice": {"text": "str"},
    "refused": {"text": "str"},
    "error": {"error": "str"},
}


# Each base type and its TypeScript.
BASE = {"str": "string", "int": "number", "bool": "boolean", "any": "unknown", "null": "null"}


def _check(value, spec, where):
    if isinstance(spec, list):
        if not isinstance(value, list):
            raise ValueError(f"{where} must be a list")
        for i, item in enumerate(value):
            _check(item, spec[0], f"{where}[{i}]")
    elif isinstance(spec, Nullable):
        if value is not None:
            _check(value, spec.spec, where)
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


def _ts(spec, indent=""):
    if isinstance(spec, list):
        inner = _ts(spec[0], indent)
        return f"Array<{inner}>"
    if isinstance(spec, Nullable):
        return f"{_ts(spec.spec, indent)} | null"
    if isinstance(spec, dict):
        fields = [f"{indent}  {json.dumps(key.rstrip('?')) if '-' in key else key.rstrip('?')}"
                  f"{'?' if key.endswith('?') else ''}: {_ts(field, indent + '  ')};"
                  for key, field in spec.items()]
        return "{\n" + "\n".join(fields) + f"\n{indent}}}" if fields else "{}"
    return " | ".join(BASE.get(kind) or json.dumps(kind) for kind in spec.split("|"))


def typescript():
    """The TypeScript types of the protocol, for pi."""
    lines = [
        "// Generated by pkgs/agent-hub/agent_hub/protocol.py at build time.",
        f"export const PROTOCOL_VERSION = {VERSION};",
        "export type HubState = HubRow[\"state\"];",
        f"export type HubIdentity = {_ts(IDENTITY)};",
        f"export type HubTurn = {_ts(TURN)};",
        f"export type HubRow = {_ts(ROW)};",
        "export type HubOp =",
        *(f"  | ({{ op: {json.dumps(op)} }} & {_ts(spec, '  ')})" for op, spec in OPS.items()),
        ";",
        "export type HubMessage =",
        *(f"  | ({{ type: {json.dumps(kind)} }} & {_ts(spec, '  ')})" for kind, spec in TYPES.items()),
        ";",
    ]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    if sys.argv[1:] != ["--typescript"]:
        sys.exit("usage: protocol.py --typescript")
    sys.stdout.write(typescript())
