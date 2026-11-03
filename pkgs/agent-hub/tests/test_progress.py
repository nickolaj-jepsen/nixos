"""A running turn's progress: transcript entries in, the row's fields out."""

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from agent_hub.progress import START_BYTES, Progress, Tail, first_line

AT = "2026-11-03T00:00:00.000Z"
AT_MS = 1793664000000


def prompt(text="go"):
    return {"type": "user", "timestamp": AT, "message": {"role": "user", "content": text}}


def said(text):
    return {"type": "assistant", "timestamp": AT, "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def call(call_id, name, **args):
    return {"type": "assistant", "timestamp": AT, "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": call_id, "name": name, "input": args}]}}


def result(call_id, error=False, **extra):
    return {"type": "user", "timestamp": AT, "toolUseResult": extra, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": call_id, "is_error": error}]}}


def fed(*entries, agent="claude"):
    progress = Progress(agent)
    for entry in entries:
        progress.feed(entry, 1)
    return progress


class ClaudeProgressTest(unittest.TestCase):
    def test_a_running_tool_is_what_it_is_doing_now(self):
        view = fed(prompt(), call("c", "Bash", command="just build\nmore")).view()
        self.assertEqual((view["now"], view["nowAt"]), ("just build", AT_MS))

    def test_a_finished_tool_is_not(self):
        self.assertNotIn("now", fed(prompt(), call("c", "Bash", command="ls"), result("c")).view())

    def test_a_subagent_goes_by_its_description(self):
        self.assertEqual(fed(prompt(), call("c", "Agent", description="Review the hub")).view()["now"], "subagent: Review the hub")

    def test_several_at_once_name_the_oldest_and_how_many_more(self):
        self.assertEqual(fed(prompt(), call("a", "Bash", command="one"), call("b", "Bash", command="two")).view()["now"], "one +1")

    def test_the_turn_tallies_edits_commands_and_failures(self):
        view = fed(prompt(), call("a", "Edit", file_path="x.py"), result("a"), call("b", "Bash", command="t"), result("b", error=True)).view()
        self.assertEqual(view["counts"], {"edits": 1, "commands": 1, "failed": 1})

    def test_narration_is_the_trail_and_the_latest_is_the_step(self):
        view = fed(prompt(), said("**First** I'll read it.\n\nDetails."), call("c", "Read"), result("c"), said("Now the fix.")).view()
        self.assertEqual([s["text"] for s in view["trail"]], ["First I'll read it.", "Now the fix."])
        self.assertEqual(view["step"], "Now the fix.")

    def test_a_new_prompt_starts_over(self):
        view = fed(prompt(), said("Old."), call("c", "Edit", file_path="x.py"), prompt("next")).view()
        self.assertEqual(view, {})

    def test_a_peers_message_starts_over_too(self):
        peer = {"type": "user", "isMeta": True, "origin": {"kind": "peer"}, "message": {"role": "user", "content": "hi"}}
        self.assertEqual(fed(prompt(), said("Old."), peer).view(), {})

    def test_a_background_job_stays_through_the_next_turn_until_it_reports(self):
        progress = fed(prompt(), call("j", "Bash", command="nix build", run_in_background=True), result("j", backgroundTaskId="t1"))
        self.assertEqual(progress.view(jobs=True)["now"], "nix build")
        progress.feed(prompt("meanwhile"), 1)
        self.assertEqual(progress.view(jobs=True)["now"], "nix build")
        progress.feed(prompt("<task-notification>\n<tool-use-id>j</tool-use-id>\n</task-notification>"), 1)
        self.assertNotIn("now", progress.view(jobs=True))

    def test_a_job_is_named_only_when_asked_since_one_can_stop_without_reporting(self):
        progress = fed(prompt(), call("j", "Bash", command="nix build"), result("j", backgroundTaskId="t1"))
        self.assertNotIn("now", progress.view())

    def test_a_job_you_stopped_is_over(self):
        progress = fed(prompt(), call("j", "Bash", command="nix build"), result("j", backgroundTaskId="t1"),
                       call("s", "TaskStop", task_id="t1"), result("s"))
        self.assertNotIn("now", progress.view(jobs=True))

    def test_a_subagents_own_entries_are_not_this_turns(self):
        side = {**said("Inside the subagent."), "isSidechain": True}
        self.assertEqual(fed(prompt(), side).view(), {})

    def test_a_trail_keeps_its_latest(self):
        view = fed(prompt(), *[said(f"step {n}") for n in range(20)]).view()
        self.assertEqual(view["trail"][0]["text"], "step 8")


class PiProgressTest(unittest.TestCase):
    def entry(self, role, content=None, **extra):
        return {"type": "message", "timestamp": AT, "message": {"role": role, "content": content or [], **extra}}

    def test_a_running_tool_narration_and_the_tally(self):
        progress = fed(self.entry("user"),
                       self.entry("assistant", [{"type": "text", "text": "Building it."},
                                                {"type": "toolCall", "id": "c", "name": "bash", "arguments": {"command": "just build"}}]),
                       agent="pi")
        view = progress.view()
        self.assertEqual((view["now"], view["step"], view["counts"]["commands"]), ("just build", "Building it.", 1))
        progress.feed(self.entry("toolResult", toolCallId="c", isError=True), 1)
        self.assertNotIn("now", progress.view())
        self.assertEqual(progress.view()["counts"]["failed"], 1)

    def test_a_new_prompt_and_a_peers_message_start_over(self):
        said_something = self.entry("assistant", [{"type": "text", "text": "Old."}])
        self.assertEqual(fed(self.entry("user"), said_something, self.entry("user"), agent="pi").view(), {})
        peer = {"type": "custom_message", "customType": "claude-peer-message", "content": "hi"}
        self.assertEqual(fed(self.entry("user"), said_something, peer, agent="pi").view(), {})


class TailTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-tail-test-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.path = self.tmp / "t.jsonl"

    def write(self, *entries, mode="a"):
        with open(self.path, mode) as out:
            out.write("".join(json.dumps(e) + "\n" for e in entries))

    def test_reads_on_from_where_it_was_and_says_when_it_moved(self):
        self.write(prompt(), said("One."))
        tail = Tail(str(self.path))
        self.assertTrue(tail.advance(1))
        self.assertFalse(tail.advance(1))
        self.write(said("Two."))
        self.assertTrue(tail.advance(1))
        self.assertEqual(len(tail.progress.view()["trail"]), 2)

    def test_a_line_half_written_waits_for_the_rest(self):
        self.write(prompt())
        tail = Tail(str(self.path))
        tail.advance(1)
        line = json.dumps(said("Whole."))
        with open(self.path, "a") as out:
            out.write(line[:10])
        self.assertFalse(tail.advance(1))
        with open(self.path, "a") as out:
            out.write(line[10:] + "\n")
        self.assertTrue(tail.advance(1))
        self.assertEqual(tail.progress.view()["step"], "Whole.")

    def test_a_long_transcript_is_read_from_near_its_end(self):
        self.write(prompt(), said("Long ago."), {"type": "user", "padding": "x" * START_BYTES})
        self.write(prompt("now"), said("Lately."))
        tail = Tail(str(self.path))
        tail.advance(1)
        self.assertEqual([s["text"] for s in tail.progress.view()["trail"]], ["Lately."])

    def test_a_transcript_gone_is_no_error(self):
        self.assertFalse(Tail(str(self.tmp / "missing.jsonl")).advance(1))

    def test_one_that_shrank_is_read_again(self):
        self.write(prompt(), said("One."), said("Two."))
        tail = Tail(str(self.path))
        tail.advance(1)
        self.write(prompt(), said("Fresh."), mode="w")
        tail.advance(1)
        self.assertEqual(tail.progress.view()["step"], "Fresh.")


class FirstLineTest(unittest.TestCase):
    def test_skips_blank_lines_and_markdown(self):
        self.assertEqual(first_line("\n\n## **Plan**\nmore"), "Plan")

    def test_nothing_to_say_is_empty(self):
        self.assertEqual(first_line("```\n"), "")
