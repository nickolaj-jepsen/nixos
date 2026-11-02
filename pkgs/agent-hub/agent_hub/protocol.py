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


# The order the bar lists states in; the first five want you.
STATES = ("asking", "needs-reply", "failed", "stalled", "done", "working", "idle")
ATTENTION = STATES[:5]

IDENTITY = {"label?": "str|null", "summary?": "str|null", "tags?": ["str"], "calls?": "int|null"}

TURN = {"at": "int", "state": "str", "did": "str"}

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
}

# Who reads a turn: pi's session file and leaf entry, or Claude's transcript.
TRANSCRIPT = {"transcript?": "str|null", "leaf?": "str|null"}

OPS = {
    # The bar and the CLI.
    "subscribe": {"version?": "int"},
    "focus": {"session": "str"},
    "focus-next": {},
    "dismiss": {"session": "str"},
    "toggle": {},
    "resume": {"session": "str"},
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
        **TRANSCRIPT,
    },
    # pi's own, or a Claude hook's for the session it names.
    "dialog": {"session?": "str", "text": "str|null"},
    "named": {"name": "str|null"},
    # No text: the call failed.
    "judged": {"request": "int", "text?": "str"},
    # Both agents; Claude's hooks name their session and say who runs it.
    "session-start": {"session": "str", "pid?": "int|null", "cwd?": "str|null", "configDir?": "str|null"},
    "session-end": {"session": "str"},
    "turn-start": {"request?": "int", "session?": "str", "prompt?": "str|null", "fromPerson?": "bool",
                   "worktreeTool?": "bool", "pid?": "int|null", "cwd?": "str|null", "configDir?": "str|null",
                   **TRANSCRIPT},
    "turn-end": {"session?": "str", "pending?": "int", "error?": "bool", "pid?": "int|null", "cwd?": "str|null",
                 "configDir?": "str|null", **TRANSCRIPT},
    "relabel": {},
}

TYPES = {
    "state": {"sessions": [ROW], "recent": [RECENT]},
    "row": {"row": Nullable(ROW), "identity": IDENTITY},
    "judge": {"request": "int", "system": "str", "prompt": "str", "maxTokens": "int", "source": "str"},
    "cancel": {"request": "int"},
    "reply": {"request": "int", "peers?": "str"},
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
