"""Reading pi: a turn's digest from its session file, and which prompts only agree."""

import os
import re

from .claude import PROMPT_CHARS, RECENT_PROMPTS, assemble, command_line, shown_path, touched
from .common import folded, json_lines

SHELL_TOOLS = ("bash", "bg_run")
WRITE_TOOLS = ("edit", "write")
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


def digest(path, leaf=None, cwd=None, prompt=None):
    """The digest of a pi session file (see `judge`) along the branch ending at entry
    `leaf`, or None when the file can't be read. `cwd` defaults to the session's own.
    `prompt` is one the file doesn't have yet, as at `before_agent_start`; a session pi
    hasn't written yet is read as empty when there is one, since pi creates the file only
    with its first message. `pending` is 0: pi reports its running jobs itself."""
    entries, header = [], {}
    try:
        for entry in json_lines(path):
            if entry.get("type") == "session":
                header = entry
            else:
                entries.append(entry)
    except FileNotFoundError:
        if not prompt:
            return None
    except OSError:
        return None
    cwd = cwd or header.get("cwd")
    prompts, files, commands, failed = [], [], [], {}
    tools, said = 0, ""
    for entry in branch(entries, leaf):
        message = entry.get("message")
        if entry.get("type") != "message" or not isinstance(message, dict):
            continue
        role = message.get("role")
        if role == "user":
            tools, said = 0, ""
            text = text_of(message)
            if not is_acknowledgement(text):
                prompts.append(text)
        elif role == "toolResult":
            failed[message.get("toolCallId")] = bool(message.get("isError"))
        elif role == "assistant":
            said = text_of(message).strip() or said
            content = message.get("content")
            for block in content if isinstance(content, list) else []:
                if not isinstance(block, dict) or block.get("type") != "toolCall":
                    continue
                tools += 1
                name, args = block.get("name"), block.get("arguments")
                args = args if isinstance(args, dict) else {}
                target = args.get("path") or args.get("file_path")
                if name in WRITE_TOOLS and isinstance(target, str):
                    files = touched(files, shown(target, cwd))
                elif name in SHELL_TOOLS and isinstance(args.get("command"), str):
                    commands.append((block.get("id"), command_line(args["command"])))
    if prompt and not is_acknowledgement(prompt):
        prompts.append(prompt)
    # The first request says what the session is for; the latest what it is doing now.
    picked = prompts[-RECENT_PROMPTS:]
    if prompts and prompts[0] not in picked:
        picked = [prompts[0], *picked]
    return assemble([folded(text)[:PROMPT_CHARS] for text in picked], files, commands, failed, said, tools, 0)
