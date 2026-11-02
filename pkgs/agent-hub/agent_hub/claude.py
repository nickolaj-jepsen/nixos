"""Reading Claude Code: a turn's digest from its transcript, and what a tool call does."""

import json
from pathlib import Path

from .common import folded, label_line, shown_block

SAID_MAX = 20_000
RECENT_PROMPTS = 4
PROMPT_CHARS = 300
MAX_FILES = 6
MAX_COMMANDS = 5
COMMAND_CHARS = 48
EDITS = ("Edit", "MultiEdit", "Write", "NotebookEdit")
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
    if entry.get("type") != "user" or entry.get("isMeta") or "toolUseResult" in entry:
        return None
    parts = [b.get("text") or "" for b in blocks(entry) if b.get("type") == "text"]
    # A background job reporting back resumes the turn; it doesn't start one.
    if not parts or parts[0].lstrip().startswith("<task-notification>"):
        return None
    return "\n".join(parts)


def command_line(command):
    line = next((part for part in str(command).splitlines() if part.strip()), "")
    return folded(line)[:COMMAND_CHARS]


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


def digest(path, cwd=None, prompt=None):
    """The digest of a Claude Code transcript (see `judge`), or None when it can't be
    read. `prompt` is one the transcript doesn't have yet, as at UserPromptSubmit."""
    requests, files, commands, failed = [], [], [], {}
    text = []
    try:
        with open(path, encoding="utf-8", errors="replace") as lines:
            for line in lines:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict) or entry.get("isSidechain"):
                    continue
                said = prompt_text(entry)
                if said is not None:
                    text = []
                    # A slash command's own lines are not the person's words.
                    if not said.lstrip().startswith("<"):
                        requests.append(folded(said)[:PROMPT_CHARS])
                    continue
                for block in blocks(entry):
                    kind = block.get("type")
                    if kind == "tool_result":
                        failed[block.get("tool_use_id")] = bool(block.get("is_error"))
                    elif entry.get("type") != "assistant":
                        continue
                    elif kind == "tool_use":
                        text = []
                        name, args = block.get("name"), block.get("input") or {}
                        if name in EDITS and edit_target(args):
                            files = touched(files, shown_path(edit_target(args), cwd))
                        elif name == "Bash" and args.get("command"):
                            commands.append((block.get("id"), command_line(args["command"])))
                    elif kind == "text":
                        text.append(block.get("text") or "")
    except OSError:
        return None
    if prompt and not prompt.lstrip().startswith("<"):
        requests.append(folded(prompt)[:PROMPT_CHARS])
    return assemble(requests[-RECENT_PROMPTS:], files, commands, failed, "\n".join(text).strip())


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
