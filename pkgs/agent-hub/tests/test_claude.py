"""Reading Claude Code: synthetic transcripts, read back through `claude.turns` and `digest`."""

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from agent_hub import claude


def prompt(text, **extra):
    return {"type": "user", "uuid": "p", "message": {"role": "user", "content": text}, **extra}


def said(text, uuid="a", timestamp="2026-11-03T00:00:00.000Z"):
    return {"type": "assistant", "uuid": uuid, "timestamp": timestamp,
            "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def call(call_id, name, **args):
    return {"type": "assistant", "uuid": call_id, "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": call_id, "name": name, "input": args}]}}


def result(call_id, error=False):
    return {"type": "user", "toolUseResult": {}, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": call_id, "is_error": error}]}}


class CommandLineTest(unittest.TestCase):
    def test_a_leading_cd_says_nothing_of_what_the_command_is(self):
        place = "/home/me/worktrees/some-repo/a-long-branch-name-that-fills-the-line"
        for command in (f"cd {place} && just build", f"cd {place}; just build", f'cd "{place}" && cd sub && just build'):
            self.assertEqual(claude.command_line(command), "just build")

    def test_a_cd_with_nothing_after_it_on_the_line_stays(self):
        self.assertEqual(claude.command_line("cd /repo &&\njust build"), "cd /repo &&")
        self.assertEqual(claude.command_line("cd /repo"), "cd /repo")


class TurnsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-claude-test-"))
        self.addCleanup(shutil.rmtree, self.tmp)

    def write(self, *entries):
        path = self.tmp / "t.jsonl"
        path.write_text("".join(json.dumps(e) + "\n" for e in entries))
        return path

    def test_files_and_commands_are_the_latest_turns_alone(self):
        path = self.write(prompt("one"), call("c1", "Edit", file_path="old.py"), call("c2", "Bash", command="just old"), result("c2"),
                          prompt("two"), call("c3", "Edit", file_path="new.py"), said("Done."))
        found = claude.digest(path)
        self.assertEqual((found["files"], found["commands"], found["said"]), (["new.py"], [], "Done."))
        self.assertEqual(found["requests"], ["one", "two"])

    def test_before_a_new_prompt_the_turn_before_still_says_what_the_work_is(self):
        path = self.write(prompt("one"), call("c1", "Edit", file_path="old.py"), said("Done."))
        found = claude.digest(path, prompt="two")
        self.assertEqual((found["files"], found["requests"]), (["old.py"], ["one", "two"]))

    def test_every_turn_is_there_for_replaying(self):
        path = self.write(prompt("one"), said("First.", uuid="a1"), prompt("two"), call("c", "Bash", command="ls"), result("c", error=True), said("Second.", uuid="a2"))
        found = claude.turns(path)
        self.assertEqual([(t["id"], t["said"]) for t in found], [("a1", "First."), ("a2", "Second.")])
        self.assertEqual(found[1]["commands"], ["ls (failed)"])

    def test_a_peers_message_starts_a_turn_marked_as_one(self):
        path = self.write(prompt("one"), said("Shall I?"), prompt("hi", isMeta=True, origin={"kind": "peer"}), said("Replied."))
        found = claude.turns(path)
        self.assertEqual([(t["peer"], t["said"]) for t in found], [(False, "Shall I?"), (True, "Replied.")])
        self.assertEqual(found[1]["requests"], ["one"])

    def test_a_job_reporting_back_carries_the_same_turn(self):
        note = prompt("<task-notification>done</task-notification>", origin={"kind": "task-notification"})
        path = self.write(prompt("one"), call("c", "Edit", file_path="a.py"), said("Waiting."), note, said("It finished."))
        found = claude.turns(path)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["files"], ["a.py"])

    def test_what_is_not_the_persons_words_is_no_request(self):
        path = self.write(prompt("one"), prompt("[Request interrupted by user]"), prompt("<command-name>/x</command-name>"),
                          prompt("summary", isCompactSummary=True))
        self.assertEqual(claude.digest(path)["requests"], ["one"])

    def test_a_transcript_that_cant_be_read_is_none(self):
        self.assertIsNone(claude.digest(self.tmp))
        self.assertIsNone(claude.turns(self.tmp / "missing.jsonl"))
