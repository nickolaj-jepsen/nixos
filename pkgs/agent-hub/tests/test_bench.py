"""The gate's benchmark: synthetic transcripts in a temp home, a fake model, and scripted answers."""

import io
import json
import random
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from agent_hub import bench, judge

FAKE_CLAUDE = """#!{python}
import os, sys
prompt = sys.stdin.read()
with open({log!r}, "a") as log:
    log.write(os.environ.get("CLAUDE_CONFIG_DIR", "-") + "\\n")
if "commit" in prompt:
    print("state: blocked\\nask: commit this?\\ndid: Did the work.")
else:
    print("state: done\\ndid: Did the work.")
"""


def entries(said_words, uuid):
    return [{"type": "user", "uuid": f"p{uuid}", "message": {"role": "user", "content": "please do it"}},
            {"type": "assistant", "uuid": uuid, "timestamp": "2026-11-03T00:00:00.000Z",
             "message": {"role": "assistant", "content": [{"type": "text", "text": said_words}]}}]


class Terminal(io.StringIO):
    def isatty(self):
        return True


class BenchTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="agent-hub-bench-test-"))
        self.addCleanup(shutil.rmtree, self.home)
        patch = mock.patch.dict("os.environ", {"HOME": str(self.home)})
        patch.start()
        self.addCleanup(patch.stop)
        self.log = self.home / "claude.log"
        claude = self.home / "claude"
        claude.write_text(FAKE_CLAUDE.format(python=sys.executable, log=str(self.log)))
        claude.chmod(0o755)
        self.cfg = {"state": str(self.home / "state" / "state.json"), "claude": str(claude)}
        self.labels = self.home / "state" / "labels.jsonl"

    def transcript(self, name, said_words, uuid, profile=".claude"):
        folder = self.home / profile / "projects" / "-repo"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{name}.jsonl"
        path.write_text("".join(json.dumps(e) + "\n" for e in entries(said_words, uuid)))
        return path

    def run_label(self, answers):
        out = io.StringIO()
        bench.label(self.cfg, stream=io.StringIO(answers), out=out, rng=random.Random(1))
        return out.getvalue()

    def lines(self):
        return [json.loads(line) for line in self.labels.read_text().splitlines()]

    def test_labels_hold_answers_and_ids_never_the_words(self):
        path = self.transcript("a", "Secret plan. Shall I commit?", "a1")
        out = self.run_label("y\ny\n")
        self.assertIn("Secret plan", out)
        line = self.lines()[0]
        self.assertEqual((line["wants"], line["didOk"], line["flagged"], line["turn"], line["path"]), (True, True, True, "a1", str(path)))
        self.assertNotIn("Secret plan", self.labels.read_text())
        self.assertNotIn("please do it", self.labels.read_text())

    def test_a_bad_prompt_takes_its_whole_session_out(self):
        folder = self.home / ".claude" / "projects" / "-repo"
        folder.mkdir(parents=True)
        turns = [e for n in range(3) for e in entries(f"Turn {n}. Shall I commit?", f"a{n}")]
        (folder / "child.jsonl").write_text("".join(json.dumps(e) + "\n" for e in turns))
        self.run_label("n\nn\nb\nn\nn\n")
        self.assertEqual([line.get("bad", False) for line in self.lines()], [False, True])
        self.assertIn("agent-hub label", self.run_eval())

    def pi_session(self, name, prompt, said_words, folder="-repo", parent=None):
        path = self.home / ".pi" / "agent" / "sessions" / folder / f"{name}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        lines = [{"type": "session", "id": name, "cwd": "/repo", **({"parentSession": str(parent)} if parent else {})},
                 {"type": "message", "id": f"{name}-u", "parentId": None,
                  "message": {"role": "user", "content": [{"type": "text", "text": prompt}]}},
                 {"type": "message", "id": f"{name}-a", "parentId": f"{name}-u", "timestamp": "2026-11-03T00:00:00.000Z",
                  "message": {"role": "assistant", "content": [{"type": "text", "text": said_words}], "stopReason": "stop"}}]
        path.write_text("".join(json.dumps(line) + "\n" for line in lines))
        return path

    def test_only_sessions_you_started_can_be_sampled(self):
        parent = self.pi_session("parent", "my own ask", "Parent words.")
        self.pi_session("fork", "my own ask", "Fork words.", parent=parent)
        self.pi_session("child", "You are a critic", "Child words.", parent=parent)
        self.pi_session("task", "Read the docs", "Task words.", folder="-repo/parent/tasks")
        self.pi_session("orphan", "Read the docs", "Orphan words.", parent=self.home / "gone.jsonl")
        self.transcript("mine", "Claude words.", "a1")
        folder = self.home / ".claude" / "projects" / "-repo"
        (folder / "scripted.jsonl").write_text("".join(json.dumps({**e, "entrypoint": "sdk-cli"}) + "\n" for e in entries("Scripted words.", "b1")))
        said = " ".join(turn["said"] for bucket in bench.sources(self.home) for source in bucket for turn in bench.endings(source))
        for kept in ("Parent words", "Fork words", "Claude words"):
            self.assertIn(kept, said)
        for dropped in ("Child words", "Task words", "Orphan words", "Scripted words"):
            self.assertNotIn(dropped, said)

    def test_a_turn_cut_short_is_not_an_ending(self):
        path = self.pi_session("kept", "my ask", "Pi ending.")
        cut = {"type": "message", "id": "cut", "parentId": "kept-a",
               "message": {"role": "assistant", "content": [{"type": "text", "text": "Pi narration."}], "stopReason": "aborted"}}
        ask = {"type": "message", "id": "ask", "parentId": "kept-a", "message": {"role": "user", "content": "next"}}
        with path.open("a") as out:
            out.write(json.dumps(ask) + "\n" + json.dumps({**cut, "parentId": "ask"}) + "\n")
        folder = self.home / ".claude" / "projects" / "-repo"
        folder.mkdir(parents=True)
        interrupt = {"type": "user", "uuid": "i1", "message": {"role": "user", "content": "[Request interrupted by user]"}}
        lines = [*entries("Claude ending.", "a1"), *entries("Claude narration.", "a2"), interrupt]
        (folder / "c.jsonl").write_text("".join(json.dumps(line) + "\n" for line in lines))
        said = " ".join(turn["said"] for bucket in bench.sources(self.home) for source in bucket for turn in bench.endings(source))
        for kept in ("Pi ending", "Claude ending"):
            self.assertIn(kept, said)
        for dropped in ("Pi narration", "Claude narration"):
            self.assertNotIn(dropped, said)

    def shown(self, out):
        turn = {"agent": "claude", "path": "/x/-repo/a.jsonl", "at": "2026-11-03T00:00:00Z", "said": "## Plan\n**Bold** word", "requests": ["do it"]}
        bench.show(turn, 0, 50, out)
        return out.getvalue()

    def test_a_terminal_gets_the_markdown_read_for_it(self):
        out = self.shown(Terminal())
        self.assertNotIn("**Bold**", out)
        self.assertNotIn("## Plan", out)

    def test_a_pipe_or_no_color_gets_the_words_as_written(self):
        self.assertIn("## Plan\n**Bold** word", self.shown(io.StringIO()))
        with mock.patch.dict("os.environ", {"NO_COLOR": "1"}):
            self.assertIn("## Plan\n**Bold** word", self.shown(Terminal()))

    def test_the_verdict_stays_hidden_while_you_answer(self):
        self.transcript("a", "Shall I commit?", "a1")
        out = self.run_label("n\n")
        self.assertNotIn("commit this?", out)
        self.assertNotIn("needs-reply", out)

    def test_quitting_keeps_what_you_said_and_carrying_on_skips_it(self):
        self.transcript("a", "Shall I commit?", "a1")
        self.transcript("b", "Want me to commit too?", "b1")
        self.run_label("y\ny\nq\n")
        first = self.lines()[0]["turn"]
        self.assertEqual(len(self.lines()), 1)
        self.run_label("n\nn\n")
        self.assertEqual({line["turn"] for line in self.lines()}, {"a1", "b1"})
        self.assertNotEqual(self.lines()[1]["turn"], first)

    def test_the_end_of_the_input_answers_nothing(self):
        self.transcript("a", "Shall I commit?", "a1")
        self.run_label("")
        self.assertFalse(self.labels.exists())

    def test_a_skipped_turn_doesnt_come_back_or_count(self):
        self.transcript("a", "Shall I commit?", "a1")
        self.run_label("s\n")
        self.assertIsNone(self.lines()[0]["wants"])
        self.run_label("y\ny\n")
        self.assertEqual(len(self.lines()), 1)

    def test_a_turn_a_peer_woke_is_not_in_the_sample(self):
        folder = self.home / ".claude" / "projects" / "-repo"
        folder.mkdir(parents=True)
        peer = {"type": "user", "isMeta": True, "origin": {"kind": "peer"}, "message": {"role": "user", "content": "hi"}}
        rows = [*entries("All done.", "a1"), peer, entries("Shall I commit?", "a2")[1]]
        (folder / "a.jsonl").write_text("".join(json.dumps(e) + "\n" for e in rows))
        self.run_label("n\nn\n")
        self.assertEqual([line["turn"] for line in self.lines()], ["a1"])

    def test_one_session_cant_fill_the_sample(self):
        folder = self.home / ".claude" / "projects" / "-repo"
        folder.mkdir(parents=True)
        rows = [e for n in range(10) for e in entries(f"Shall I commit {n}?", f"a{n}")]
        (folder / "a.jsonl").write_text("".join(json.dumps(e) + "\n" for e in rows))
        self.run_label("n\nn\n" * 10)
        self.assertEqual(len(self.lines()), bench.SESSION_MAX)

    def test_a_work_session_is_read_as_the_work_profile(self):
        self.transcript("a", "Shall I commit?", "a1", profile=".claude-work")
        self.run_label("n\nn\n")
        self.assertEqual(self.log.read_text().split(), [str(self.home / ".claude-work")])

    def label_as(self, path, turn, wants, flagged=True):
        self.labels.parent.mkdir(parents=True, exist_ok=True)
        with open(self.labels, "a") as out:
            out.write(json.dumps({"agent": "claude", "path": str(path), "turn": turn, "flagged": flagged, "wants": wants, "didOk": True}) + "\n")

    def run_eval(self, **kw):
        out = io.StringIO()
        bench.evaluate(self.cfg, out=out, **kw)
        return out.getvalue()

    def test_eval_counts_a_hit_a_false_alarm_and_a_miss_the_regex_never_reached(self):
        self.label_as(self.transcript("a", "Shall I commit?", "a1"), "a1", True)
        self.label_as(self.transcript("b", "Want me to commit?", "b1"), "b1", False)
        self.label_as(self.transcript("c", "All built. Over to you for the reboot.", "c1"), "c1", True, flagged=False)
        out = self.run_eval()
        self.assertIn(judge.VERSION, out)
        self.assertIn("recall: 1/2 = 50%", out)
        self.assertIn("precision: 1/2 = 50%", out)
        self.assertIn("asks the regex reached: 1/2", out)
        self.assertIn("missed: c1", out)
        self.assertIn("false alarm: b1", out)
        self.assertIn("not met", out)

    def test_the_words_alone_make_no_model_call(self):
        self.label_as(self.transcript("a", "Shall I commit?", "a1"), "a1", True)
        out = self.run_eval(words_only=True)
        self.assertIn("recall: 1/1 = 100%", out)
        self.assertFalse(self.log.exists())

    def test_a_transcript_gone_is_counted_not_fatal(self):
        self.label_as(self.home / "gone.jsonl", "x", True)
        self.label_as(self.transcript("a", "Shall I commit?", "a1"), "a1", True)
        self.assertIn("1 no longer readable", self.run_eval(words_only=True))

    def test_eval_says_how_often_an_unverified_marker_would_fire(self):
        folder = self.home / ".claude" / "projects" / "-repo"
        folder.mkdir(parents=True)
        edit = {"type": "assistant", "uuid": "e", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": "t", "name": "Edit", "input": {"file_path": "a.py"}}]}}
        rows = [entries("x", "a1")[0], edit, entries("Fixed it.", "a1")[1]]
        (folder / "a.jsonl").write_text("".join(json.dumps(e) + "\n" for e in rows))
        self.label_as(folder / "a.jsonl", "a1", False, flagged=False)
        self.assertIn("would fire on 1 of 1 editing turns, 1 of them", self.run_eval(words_only=True))

    def test_no_labels_says_so(self):
        self.assertIn("agent-hub label", self.run_eval())


class WilsonTest(unittest.TestCase):
    def test_a_small_sample_has_a_wide_interval(self):
        low, high = bench.wilson(15, 15)
        self.assertLess(low, 0.85)
        self.assertEqual(high, 1.0)

    def test_nothing_to_go_on_says_nothing(self):
        self.assertEqual(bench.wilson(0, 0), (0.0, 1.0))
