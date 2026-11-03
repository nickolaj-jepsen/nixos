"""How far a running turn has got, read off its transcript as it grows, with no model call.

`Progress` is pure: fed one transcript entry at a time, it keeps the agent's own narration
(the trail), the tools running now and the turn's counts. `Tail` follows the file. All of it
stays in the daemon's memory: narration is the agent's words, so it stays off the state file and
the work log, and comes back from the transcript after a restart.
"""

import json
import os
import re
from datetime import datetime

from .claude import EDITS, blocks, command_line, edit_target, peer_message, prompt_text, shown_path
from .common import folded
from .pi import PEER_MESSAGE, SHELL_TOOLS, WRITE_TOOLS

TRAIL_MAX = 12
STEP_CHARS = 160
# What the row's own step line holds; the pane shows the rest.
DOING_CHARS = 80
LINE_CHARS = 80
# A restart mid-turn reads this much of the end, not a transcript that can run to tens of megabytes.
START_BYTES = 2 << 20
MARKDOWN = re.compile(r"[*`#>]+")
NOTIFIED = re.compile(r"<tool-use-id>([^<:]+)")


def stamp(value, fallback):
    """A transcript's ISO time as ms, or `fallback`."""
    try:
        return int(datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return fallback


def first_line(text):
    """The opening line of what the agent said, as one step of the trail."""
    for line in str(text).splitlines():
        line = folded(MARKDOWN.sub("", line))
        if line:
            return line[:STEP_CHARS]
    return ""


def claude_line(name, args, cwd):
    if name == "Bash":
        return command_line(args.get("command") or "") or name
    if name in EDITS and edit_target(args):
        return f"editing {shown_path(edit_target(args), cwd)}"[:LINE_CHARS]
    if name in ("Agent", "Task") and args.get("description"):
        return f"subagent: {folded(args['description'])}"[:LINE_CHARS]
    return str(name)[:LINE_CHARS]


def pi_line(name, args):
    if name in SHELL_TOOLS and isinstance(args.get("command"), str):
        return command_line(args["command"]) or name
    target = args.get("path") or args.get("file_path")
    if name in WRITE_TOOLS and isinstance(target, str):
        return f"editing {target}"[:LINE_CHARS]
    return str(name)[:LINE_CHARS]


class Progress:
    def __init__(self, agent="claude", cwd=None):
        self.agent, self.cwd = agent, cwd
        self.jobs = {}
        self.new_turn()

    def new_turn(self):
        """A new turn: what ran in the last one is over, but its background jobs aren't."""
        self.steps, self.running = [], {}
        self.edits = self.commands = self.failed = 0

    def _say(self, text, at):
        line = first_line(text)
        if line:
            self.steps = [*self.steps, {"at": at, "text": line}][-TRAIL_MAX:]

    def _call(self, call_id, line, at, edit=False, command=False):
        self.running[call_id] = {"line": line, "at": at}
        self.edits += edit
        self.commands += command

    def feed(self, entry, now):
        (self._feed_pi if self.agent == "pi" else self._feed_claude)(entry, now)

    def _feed_claude(self, entry, now):
        if entry.get("isSidechain"):
            return
        at = stamp(entry.get("timestamp"), now)
        if peer_message(entry) or prompt_text(entry) is not None:
            self.new_turn()
            return
        for block in blocks(entry):
            kind = block.get("type")
            if entry.get("type") == "assistant" and kind == "text":
                self._say(block.get("text"), at)
            elif entry.get("type") == "assistant" and kind == "tool_use":
                name, args = block.get("name"), block.get("input") or {}
                if name == "TaskStop":
                    self.jobs = {call: job for call, job in self.jobs.items() if job.get("task") != args.get("task_id")}
                self._call(block.get("id"), claude_line(name, args, self.cwd), at, name in EDITS and bool(edit_target(args)), name == "Bash")
            elif kind == "tool_result":
                self._result(block.get("tool_use_id"), bool(block.get("is_error")), entry.get("toolUseResult"), at)
            elif kind == "text":
                self._notified(block.get("text"), at)

    def _result(self, call_id, error, result, at):
        call = self.running.pop(call_id, None)
        self.failed += error
        # A background job's tool call returns at once, and the job goes on.
        if call and isinstance(result, dict) and (result.get("backgroundTaskId") or result.get("isAsync")):
            self.jobs[call_id] = {**call, "at": at, "task": result.get("backgroundTaskId") or result.get("agentId")}

    def _notified(self, text, _at):
        """A background job reporting back, which names the tool call that started it."""
        if text and str(text).lstrip().startswith("<task-notification>"):
            for call_id in NOTIFIED.findall(text):
                self.jobs.pop(call_id, None)

    def _feed_pi(self, entry, now):
        at = stamp(entry.get("timestamp"), now)
        if entry.get("type") == "custom_message" and entry.get("customType") == PEER_MESSAGE:
            self.new_turn()
            return
        message = entry.get("message")
        if entry.get("type") != "message" or not isinstance(message, dict):
            return
        role = message.get("role")
        if role == "user":
            self.new_turn()
        elif role == "toolResult":
            self.running.pop(message.get("toolCallId"), None)
            self.failed += bool(message.get("isError"))
        elif role == "assistant":
            content = message.get("content")
            for block in content if isinstance(content, list) else []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    self._say(block.get("text"), at)
                elif block.get("type") == "toolCall":
                    name, args = block.get("name"), block.get("arguments")
                    args = args if isinstance(args, dict) else {}
                    target = args.get("path") or args.get("file_path")
                    self._call(block.get("id"), pi_line(name, args), at, name in WRITE_TOOLS and isinstance(target, str),
                               name in SHELL_TOOLS)

    def view(self, jobs=False):
        """The row's fields: `now` and `nowAt` (what is running and since when), `counts`, `trail`
        and `step` (the latest narration, cut for a row). `jobs` also names background jobs, for
        a turn that ended to wait on them: one can stop without ever reporting, so only the
        agent's word that jobs are out makes them worth naming."""
        fields = {}
        running = list(self.running.values()) or (list(self.jobs.values()) if jobs else [])
        if running:
            oldest = min(running, key=lambda call: call["at"])
            fields["now"] = oldest["line"] + (f" +{len(running) - 1}" if len(running) > 1 else "")
            fields["nowAt"] = oldest["at"]
        if self.edits or self.commands or self.failed:
            fields["counts"] = {"edits": self.edits, "commands": self.commands, "failed": self.failed}
        if self.steps:
            fields["trail"] = list(self.steps)
            fields["step"] = self.steps[-1]["text"][:DOING_CHARS]
        return fields


class Tail:
    """A transcript followed from where it was last read, feeding a `Progress`."""

    def __init__(self, path, agent="claude", cwd=None):
        self.path = path
        self.offset = 0
        self.progress = Progress(agent, cwd)

    def advance(self, now):
        """Reads what was added since last time; returns whether the progress moved."""
        try:
            size = os.stat(self.path).st_size
            if size == self.offset:
                return False
            if size < self.offset:
                self.offset = 0
            with open(self.path, "rb") as transcript:
                if self.offset == 0 and size > START_BYTES:
                    # The first of it is the rest of a line cut in two.
                    transcript.seek(size - START_BYTES)
                    transcript.readline()
                    self.offset = transcript.tell()
                else:
                    transcript.seek(self.offset)
                data = transcript.read()
        except OSError:
            return False
        end = data.rfind(b"\n")
        if end < 0:
            return False
        self.offset += end + 1
        before = self.progress.view()
        for line in data[:end].split(b"\n"):
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                self.progress.feed(entry, now)
        return self.progress.view() != before
