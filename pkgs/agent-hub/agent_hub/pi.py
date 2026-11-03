"""Reading pi: a turn's digest from its session file, and which prompts only agree."""

import os
import re

from .claude import PROMPT_CHARS, RECENT_PROMPTS, assemble, command_line, shown_path, touched
from .common import folded, json_lines

SHELL_TOOLS = ("bash", "bg_run")
WRITE_TOOLS = ("edit", "write")
# The custom message type claude-peers.ts puts a peer's message in the session as.
PEER_MESSAGE = "claude-peer-message"
# Bare acknowledgements only. A word count cannot tell "sounds good, but make it async"
# from "sounds good", and dropping that sentence freezes the name on the work before it.
ACK = frozenset(
    "ok okay k yes yeah yep yup sure continue proceed thanks thank ty lgtm agreed agree perfect great nice cool"
    " fine good sounds right correct carry on next go ahead do it please".split()
)


def is_acknowledgement(text):
    """True when `text` only agrees, continues or thanks: nothing to re-read the work for."""
    words = re.findall(r"[a-z']+", str(text).lower())
    return 0 < len(words) <= 3 and all(word in ACK for word in words)


def text_of(message):
    content = message.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return "\n".join(str(b.get("text") or "") for b in content if isinstance(b, dict) and b.get("type") == "text")


def branch(entries, leaf):
    """The entries from the root to `leaf`, or to the last one appended when `leaf` is
    unknown, as pi itself falls back. Siblings left by a rewind are not on it."""
    by_id = {entry["id"]: entry for entry in entries if entry.get("id")}
    current = by_id.get(leaf) or (entries[-1] if entries else None)
    path, seen = [], set()
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        path.append(current)
        current = by_id.get(current.get("parentId"))
    return path[::-1]


def shown(path, cwd):
    # pi's tools strip a leading @, expand ~ and resolve against the session's cwd.
    path = os.path.expanduser(str(path).removeprefix("@"))
    if cwd and not os.path.isabs(path):
        path = os.path.join(cwd, path)
    return shown_path(os.path.normpath(path), cwd)


def picked_requests(prompts):
    """The first request says what the session is for; the latest what it is doing now."""
    picked = prompts[-RECENT_PROMPTS:]
    if prompts and prompts[0] not in picked:
        picked = [prompts[0], *picked]
    return [folded(text)[:PROMPT_CHARS] for text in picked]


def read_entries(path):
    """A session file's entries and its header. OSError when it can't be read."""
    entries, header = [], {}
    for entry in json_lines(path):
        if entry.get("type") == "session":
            header = entry
        else:
            entries.append(entry)
    return entries, header


def turns(entries, leaf=None, cwd=None):
    """Every turn along the branch ending at entry `leaf`, oldest first (see `claude.turns`),
    with `prompts` the person's substantive requests so far, for what comes next."""
    found, prompts = [], []
    turn = None

    def begin(peer):
        nonlocal turn
        turn = {"prompts": list(prompts), "files": [], "commands": [], "failed": {}, "said": "", "id": None, "at": None, "peer": peer}
        found.append(turn)

    for entry in branch(entries, leaf):
        if entry.get("type") == "custom_message" and entry.get("customType") == PEER_MESSAGE:
            begin(True)
            continue
        message = entry.get("message")
        if entry.get("type") != "message" or not isinstance(message, dict):
            continue
        role = message.get("role")
        if role == "user":
            text = text_of(message)
            if not is_acknowledgement(text):
                prompts.append(text)
            begin(False)
        elif turn is None:
            continue
        elif role == "toolResult":
            turn["failed"][message.get("toolCallId")] = bool(message.get("isError"))
        elif role == "assistant":
            turn["said"] = text_of(message).strip() or turn["said"]
            turn["id"], turn["at"] = entry.get("id"), entry.get("timestamp")
            content = message.get("content")
            for block in content if isinstance(content, list) else []:
                if not isinstance(block, dict) or block.get("type") != "toolCall":
                    continue
                name, args = block.get("name"), block.get("arguments")
                args = args if isinstance(args, dict) else {}
                target = args.get("path") or args.get("file_path")
                if name in WRITE_TOOLS and isinstance(target, str):
                    turn["files"] = touched(turn["files"], shown(target, cwd))
                elif name in SHELL_TOOLS and isinstance(args.get("command"), str):
                    turn["commands"].append((block.get("id"), command_line(args["command"])))
    return [{**assemble(picked_requests(t["prompts"]), t["files"], t["commands"], t["failed"], t["said"]),
             "id": t["id"], "at": t["at"], "peer": t["peer"], "prompts": t["prompts"]} for t in found], prompts


def digest(path, leaf=None, cwd=None, prompt=None):
    """The digest of a pi session file's latest turn (see `judge`) along the branch ending at
    entry `leaf`, or None when the file can't be read. `cwd` defaults to the session's own.
    `prompt` is one the file doesn't have yet, as at `before_agent_start`; a session pi
    hasn't written yet is read as empty when there is one, since pi creates the file only
    with its first message. pi reports its running jobs itself."""
    entries, header = [], {}
    try:
        entries, header = read_entries(path)
    except FileNotFoundError:
        if not prompt:
            return None
    except OSError:
        return None
    found, prompts = turns(entries, leaf, cwd or header.get("cwd"))
    latest = found[-1] if found else assemble([], [], [], {}, "")
    if prompt and not is_acknowledgement(prompt):
        prompts = [*prompts, prompt]
    return {**latest, "requests": picked_requests(prompts)}
