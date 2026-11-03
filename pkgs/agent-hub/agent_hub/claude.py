"""Reading Claude Code: a turn's digest from its transcript, and what a tool call does."""

import json
import re
from pathlib import Path

from .common import folded, label_line, shown_block

SAID_MAX = 20_000
RECENT_PROMPTS = 4
PROMPT_CHARS = 300
MAX_FILES = 6
MAX_COMMANDS = 5
COMMAND_CHARS = 48
EDITS = ("Edit", "MultiEdit", "Write", "NotebookEdit")
# A command that checks work. Rough: `agent-hub eval` says how often it would mislead.
CHECK = re.compile(r"\b(test|tests|pytest|unittest|just (build|check|eval|test)|nix (build|flake check)|cargo|npm|pnpm|tsc|ruff|mypy|lint|make)\b")
# Says where a command runs, not what it is, and a long path would use up all of its line.
LEADING_CD = re.compile(r"""^\s*(?:cd\s+(?:"[^"]*"|'[^']*'|\S+)\s*(?:&&|;)\s*)+""")
# `claude -p` as a judge: no session file, no tools, no MCP, no hooks of its own.
JUDGE_ARGS = [
    "-p", "--model", "haiku", "--no-session-persistence", "--strict-mcp-config", "--tools", "",
    "--disable-slash-commands", "--settings", json.dumps({"disableAllHooks": True}),
]


def blocks(entry):
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []


def prompt_text(entry):
    """What the person typed, when a transcript entry is a prompt that starts a turn."""
    if entry.get("type") != "user" or entry.get("isMeta") or entry.get("isCompactSummary") or "toolUseResult" in entry:
        return None
    parts = [b.get("text") or "" for b in blocks(entry) if b.get("type") == "text"]
    # A background job reporting back resumes the turn; it doesn't start one.
    if not parts or parts[0].lstrip().startswith("<task-notification>"):
        return None
    return "\n".join(parts)


def peer_message(entry):
    """Whether a transcript entry is another session's message, which starts a turn too."""
    origin = entry.get("origin")
    return entry.get("type") == "user" and isinstance(origin, dict) and origin.get("kind") == "peer"


def queued_text(entry):
    """What was queued into a running turn, or None. Claude files that as an attachment, so it
    is no prompt: a background job reporting back, or a message that waits for the next step."""
    attachment = entry.get("attachment")
    if entry.get("type") != "attachment" or not isinstance(attachment, dict) or attachment.get("type") != "queued_command":
        return None
    text = attachment.get("prompt")
    return text if isinstance(text, str) else None


def command_line(command):
    line = next((part for part in str(command).splitlines() if part.strip()), "")
    return folded(LEADING_CD.sub("", line) or line)[:COMMAND_CHARS]


def touched(files, path):
    """`files` with `path` moved to the end, the latest touched last."""
    return [f for f in files if f != path] + [path]


def assemble(requests, files, commands, failed, said):
    """A digest from what a transcript reader collected: `commands` as (call id, line)
    pairs, `failed` as call id → whether its result was an error."""
    outcomes = {True: " (failed)", False: " (ok)"}
    return {
        "requests": requests,
        "files": files[-MAX_FILES:],
        "commands": [line + outcomes.get(failed.get(call), "") for call, line in commands[-MAX_COMMANDS:]],
        "said": said[-SAID_MAX:],
    }


def edit_target(args):
    return args.get("file_path") or args.get("notebook_path")


def turns(path, cwd=None):
    """Every turn of a Claude Code transcript (see `judge`), oldest first, or None when it
    can't be read. Each is a digest with `id` (its last entry), `at` (that entry's stamp,
    a string), `peer` and `unchecked` (None without an edit, else whether no command checked
    the work after the last one), and `files` and `commands` are that turn's alone."""
    found, requests = [], []
    turn = None

    def begin(peer):
        nonlocal turn
        turn = {"requests": requests[-RECENT_PROMPTS:], "files": [], "commands": [], "failed": {}, "text": [],
                "id": None, "at": None, "peer": peer, "unchecked": None}
        found.append(turn)

    try:
        with open(path, encoding="utf-8", errors="replace") as lines:
            for line in lines:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict) or entry.get("isSidechain"):
                    continue
                if peer_message(entry):
                    begin(True)
                    continue
                said = prompt_text(entry)
                if said is not None:
                    # A slash command's own lines and an interrupt's marker are not the person's words.
                    if not said.lstrip().startswith(("<", "[Request interrupted")):
                        requests.append(folded(said)[:PROMPT_CHARS])
                    begin(False)
                    continue
                if turn is None:
                    continue
                for block in blocks(entry):
                    kind = block.get("type")
                    if kind == "tool_result":
                        turn["failed"][block.get("tool_use_id")] = bool(block.get("is_error"))
                    elif entry.get("type") != "assistant":
                        continue
                    elif kind == "tool_use":
                        turn["text"] = []
                        name, args = block.get("name"), block.get("input") or {}
                        if name in EDITS and edit_target(args):
                            turn["files"] = touched(turn["files"], shown_path(edit_target(args), cwd))
                            turn["unchecked"] = True
                        elif name == "Bash" and args.get("command"):
                            turn["commands"].append((block.get("id"), command_line(args["command"])))
                            if turn["unchecked"] and CHECK.search(str(args["command"])):
                                turn["unchecked"] = False
                    elif kind == "text":
                        turn["text"].append(block.get("text") or "")
                if entry.get("type") == "assistant":
                    turn["id"], turn["at"] = entry.get("uuid"), entry.get("timestamp")
    except OSError:
        return None
    return [{**assemble(t["requests"], t["files"], t["commands"], t["failed"], "\n".join(t["text"]).strip()),
             "id": t["id"], "at": t["at"], "peer": t["peer"], "unchecked": t["unchecked"]} for t in found]


def digest(path, cwd=None, prompt=None):
    """The digest of a Claude Code transcript's latest turn (see `judge`), or None when it
    can't be read. `prompt` is one the transcript doesn't have yet, as at UserPromptSubmit:
    the turn before it is then the latest, which still says what the work is."""
    found = turns(path, cwd)
    if found is None:
        return None
    latest = found[-1] if found else assemble([], [], [], {}, "")
    if prompt and not prompt.lstrip().startswith("<"):
        latest = {**latest, "requests": [*latest["requests"], folded(prompt)[:PROMPT_CHARS]][-RECENT_PROMPTS:]}
    return latest


def shown_path(path, cwd):
    path = str(path)
    if cwd and path.startswith(cwd.rstrip("/") + "/"):
        return path[len(cwd.rstrip("/")) + 1:]
    home = str(Path.home())
    return "~" + path[len(home):] if path.startswith(home + "/") else path


def claude_label(tool, args, cwd):
    """One line naming what a Claude Code tool call would do."""
    tool = str(tool or "")
    args = args if isinstance(args, dict) else {}
    if tool.startswith("mcp__"):
        server, _, name = tool[len("mcp__"):].partition("__")
        return f"{server} · {name}"
    if tool == "Bash":
        value = args.get("command")
    elif tool in EDITS:
        target = edit_target(args)
        value = shown_path(target, cwd) if target else None
    elif tool == "WebFetch":
        value = args.get("url")
    elif tool == "WebSearch":
        value = args.get("query")
    else:
        value = None
    return label_line(f"{tool}: {value}") if value else tool


def diff_lines(old, new):
    """`old` and `new` as lines of a diff, without working out what they share."""
    removed = [f"- {line}" for line in str(old or "").splitlines()]
    added = [f"+ {line}" for line in str(new or "").splitlines()]
    return removed + added


def edit_diff(tool, args):
    if tool == "MultiEdit":
        edits = args.get("edits") if isinstance(args.get("edits"), list) else []
        return "\n\n".join("\n".join(diff_lines(e.get("old_string"), e.get("new_string"))) for e in edits if isinstance(e, dict))
    if tool == "Write":
        return "\n".join(diff_lines("", args.get("content")))
    if tool == "NotebookEdit":
        return "\n".join(diff_lines("", args.get("new_source")))
    return "\n".join(diff_lines(args.get("old_string"), args.get("new_string")))


def permission_ask(tool, args, cwd):
    """All of what a permission prompt asks (`protocol.ASK`), for reading before answering it."""
    tool = str(tool or "")
    args = args if isinstance(args, dict) else {}
    about, kind = "", "text"
    if tool.startswith("mcp__"):
        server, _, name = tool[len("mcp__"):].partition("__")
        about, body = f"{server} · {name}", json.dumps(args, indent=2)
    elif tool == "Bash":
        about, kind, body = folded(args.get("description") or ""), "command", str(args.get("command") or "")
    elif tool in EDITS:
        target = edit_target(args)
        about, kind, body = shown_path(target, cwd) if target else "", "diff", edit_diff(tool, args)
    elif tool == "WebFetch":
        about, body = folded(args.get("prompt") or ""), str(args.get("url") or "")
    elif tool == "WebSearch":
        body = str(args.get("query") or "")
    else:
        body = json.dumps(args, indent=2)
    text, complete = shown_block(body)
    return {"tool": tool, "about": label_line(about), "kind": kind, "body": text, "complete": complete}
