"""Reading Claude Code: a turn's digest from its transcript, and what a tool call does."""

import json
import re
from pathlib import Path

from .common import folded, label_line

# A turn this short that ran no tools is read at a glance, so the model is not asked about it.
WORTH_ASKING_CHARS = 800
SAID_MAX = 20_000
RECENT_PROMPTS = 4
PROMPT_CHARS = 300
MAX_FILES = 6
MAX_COMMANDS = 5
COMMAND_CHARS = 48
EDITS = ("Edit", "MultiEdit", "Write", "NotebookEdit")
TASK_ID = re.compile(r"<task-id>([^<]+)</task-id>")
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


def assemble(requests, files, commands, failed, said, tools, pending):
    """A digest from what a transcript reader collected: `commands` as (call id, line)
    pairs, `failed` as call id → whether its result was an error, `tools` the calls
    since the last prompt."""
    outcomes = {True: " (failed)", False: " (ok)"}
    return {
        "requests": requests,
        "files": files[-MAX_FILES:],
        "commands": [line + outcomes.get(failed.get(call), "") for call, line in commands[-MAX_COMMANDS:]],
        "said": said[-SAID_MAX:],
        "pending": pending,
        "worth": tools > 0 or len(said) >= WORTH_ASKING_CHARS,
    }


def edit_target(args):
    return args.get("file_path") or args.get("notebook_path")


def digest(path, cwd=None, prompt=None):
    """The digest of a Claude Code transcript (see `judge`), or None when it can't be
    read. `prompt` is one the transcript doesn't have yet, as at UserPromptSubmit.
    `pending` counts background jobs that never reported back: a dev server it left
    running is pending too, which only the closing words tell apart."""
    started, finished = set(), set()
    requests, files, commands, failed = [], [], [], {}
    tools, text = 0, []
    try:
        with open(path, encoding="utf-8", errors="replace") as lines:
            for line in lines:
                if "<task-notification>" in line:
                    finished.update(TASK_ID.findall(line))
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict) or entry.get("isSidechain"):
                    continue
                result = entry.get("toolUseResult")
                if isinstance(result, dict):
                    job = result.get("backgroundTaskId") or (result.get("agentId") if result.get("isAsync") else None)
                    if job:
                        started.add(str(job))
                said = prompt_text(entry)
                if said is not None:
                    tools, text = 0, []
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
                        tools, text = tools + 1, []
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
    return assemble(requests[-RECENT_PROMPTS:], files, commands, failed, "\n".join(text).strip(), tools,
                    len(started - finished))


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
