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
# The custom message type claude-peers.ts puts a peer's message in a pi session as.
PEER_MESSAGE = "claude-peer-message"


class Nullable:
    def __init__(self, spec):
        self.spec = spec


# The order the bar lists states in; the first four want you.
STATES = ("asking", "needs-reply", "failed", "done", "working", "idle")
ATTENTION = STATES[:4]

IDENTITY = {"label?": "str|null", "summary?": "str|null", "tags?": ["str"], "calls?": "int|null"}

TURN = {"at": "int", "state": "str", "did": "str"}

# One note of a session's, for the reader: why it is listed, and what it is called in a list.
NOTE = {"path": "str", "name": "str", "group": "written|read|project", "at": "int"}

# What a permission prompt asks, in full. `complete` is false when `body` had to be cut,
# and then nothing may allow it from the bar: you can't approve what you can't read.
ASK = {"tool": "str", "about": "str", "kind": "command|diff|text", "body": "str", "complete": "bool"}

# What a surface draws of a session's answer form (`forms.view`).
FORM_ENTRY = {"kind": "option|accept|write", "text": "str", "detail": "str", "isRecommended": "bool", "isChosen": "bool"}
FORM_ITEM = {"label": "str", "title": "str", "body": "str", "entries": [FORM_ENTRY], "start": "int", "note": "str", "written": "str"}
FORM_VIEW = {
    "id": "str",
    "kind": "round|picks",
    "title": "str",
    "count": "int",
    "answered": "int",
    "step": "int",
    "isReview": "bool",
    # The item shown; null on the review.
    "item": Nullable(FORM_ITEM),
    "review": [{"label": "str", "shown": "str", "isAnswered": "bool", "note": "str"}],
    "note": "str",
    "reply": "str",
    # A reply was left for the session's TUI, which has yet to take it.
    "pending": "bool",
}

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
    # How its turn ended, of those that call you: one of `judge.ENDINGS`.
    "askKind?": "str",
    # Why its model is no longer asked, so its row stops updating: failing or capped.
    "readings?": "str",
    # The prompt a hook is holding open, which `answer` can settle by this `id`.
    "permission?": {"id": "int", **ASK},
    # The form the last turn asks to be answered with. This host's own: a link never carries it.
    "answer?": FORM_VIEW,
    "branch?": "str",
    # How many files have uncommitted changes.
    "changed?": "int",
    # The other sessions in the same working tree, by name.
    "peers?": ["str"],
    # While working, when its transcript last moved.
    "activity?": "int",
    # The background work a finished turn still waits on.
    "jobs?": ["str"],
    # While working: what is running and since when, this turn's tally, and the agent's narration so far.
    "now?": "str",
    "nowAt?": "int",
    "counts?": {"edits": "int", "commands": "int", "failed": "int"},
    "trail?": [{"at": "int", "text": "str"}],
    # A model's estimate for a command that has run long: minutes left when it was made.
    "estimate?": {"left": "int|null", "note": "str", "at": "int", "after?": "int"},
    # How many notes it wrote or read, and the one it wrote last; `new` if during this turn.
    "notes?": "int",
    "note?": {"path": "str", "name": "str", "at": "int", "new?": "bool"},
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
    # `local`: this host's own sessions, leaving out what it links in. `bar`: it can show `show`.
    "subscribe": {"version?": "int", "local?": "bool", "bar?": "bool"},
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
    # One step of a session's answer form, when `form` is still the one showing (`forms.apply`).
    "form-step": {"session": "str", "form": "str", "action": {"do": "str", "entry?": "int", "step?": "int", "text?": "str"}},
    # Leaves the form's reply for the session's TUI: in its prompt, or with `submit` sent.
    "form-deliver": {"session": "str", "form": "str", "submit": "bool"},
    # `agent-hub answer` changed a form's file.
    "form-changed": {"session": "str"},
    # Asks for a row's folder or git menu, answered with `menu`, twice when a lookup follows.
    "menu": {"request": "int", "session": "str", "which": "folder|git"},
    # Does what a menu row says.
    "run": {"session": "str", "kind": "url|copy|app|note", "value": "str"},
    # Lists a session's notes, answered in `reply.notes`; `path` alone lists that note's project.
    "notes": {"request": "int", "session?": "str", "path?": "str"},
    # One note, answered in `reply.note`: HTML to the bar, its text to another hub. Sent the
    # `at` it last answered, a note that hasn't moved answers `unchanged`.
    "note": {"request": "int", "path": "str", "session?": "str", "at?": "int"},
    # Puts the reader up at the bar, on this session, and answers whether a bar took it. With no
    # session it means the one the pid is under, else the focused window's.
    "show": {"request?": "int", "session?": "str", "pid?": "int", "path?": "str", "toggle?": "bool"},
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
                      "tmux?": "str|null", **TRANSCRIPT},
    "session-end": {"session": "str"},
    # `peer`: another session's message woke it, so what the row stands on stays.
    "turn-start": {"request?": "int", "session?": "str", "prompt?": "str|null", "fromPerson?": "bool", "peer?": "bool",
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
    "reply": {"request": "int", "peers?": "str", "decision?": "allow|deny", "facts?": "any", "notes?": [NOTE],
              "note?": "any", "shown?": "bool"},
    "menu": {"request": "int", "menu": "any"},
    "show": {"session": "str|null", "path": "str|null", "toggle": "bool"},
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
        f"export const PEER_MESSAGE_TYPE = {json.dumps(PEER_MESSAGE)};",
        "export type HubState = HubRow[\"state\"];",
        f"export type HubIdentity = {_ts(IDENTITY)};",
        f"export type HubTurn = {_ts(TURN)};",
        f"export type HubFormView = {_ts(FORM_VIEW)};",
        f"export type HubRow = {_ts(ROW)};",
        f"export type HubNote = {_ts(NOTE)};",
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
