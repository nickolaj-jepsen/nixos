"""What the work log derives from your next prompt."""

import shutil
import tempfile
import unittest
from pathlib import Path

from agent_hub.worklog import append, estimate_errors, job_key, job_line, next_prompt, past_minutes

ASKED = {"state": "blocked", "reply": "keep it"}
DONE = {"state": "done", "reply": ""}


class JobTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-worklog-test-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.log = self.tmp / "log.jsonl"

    def test_a_command_is_known_by_its_first_words_without_a_secret(self):
        self.assertEqual(job_key("TOKEN=abc just build --impure"), "just build")

    def test_past_runs_are_the_same_commands_latest_few(self):
        for minutes in range(1, 8):
            append(self.log, {"at": minutes, "job": "just build", "ms": minutes * 60_000})
        append(self.log, {"at": 9, "job": "just check", "ms": 99 * 60_000})
        self.assertEqual(past_minutes(self.log, "just build --impure"), [3, 4, 5, 6, 7])

    def test_an_estimate_is_kept_beside_what_it_took_and_can_be_scored(self):
        line = job_line({"session": "s"}, {"line": "just build", "ms": 40 * 60_000, "estimate": {"left": 5, "note": "", "after": 30 * 60_000}}, 1)
        self.assertEqual((line["job"], line["left"], line["after"]), ("just build", 5, 30 * 60_000))
        append(self.log, line)
        self.assertEqual(estimate_errors(self.log), [5.0])

    def test_no_estimate_scores_nothing(self):
        append(self.log, job_line({"session": "s"}, {"line": "just build", "ms": 60_000, "estimate": None}, 1))
        self.assertEqual(estimate_errors(self.log), [])


class NextPromptTest(unittest.TestCase):
    def test_an_ask_followed_by_a_prompt_was_answered(self):
        line = next_prompt(ASKED, "keep it")
        self.assertEqual((line["next"], line["words"], line["replyMatch"]), ("answered", 2, 1.0))

    def test_a_finished_turn_followed_by_a_prompt_was_moved_on_from(self):
        self.assertEqual(next_prompt(DONE, "now the signup form"), {"next": "moved-on", "words": 4})

    def test_a_prompt_that_pushes_back_corrected_it(self):
        for words in ("no, the other one", "That's not what I asked", "it still fails", "you forgot the test"):
            self.assertEqual(next_prompt(DONE, words)["next"], "corrected")
        self.assertEqual(next_prompt(ASKED, "not what I meant")["next"], "corrected")

    def test_a_word_that_merely_starts_like_one_is_not(self):
        self.assertEqual(next_prompt(DONE, "notes go in the docs")["next"], "moved-on")

    def test_a_turn_cut_short_was_interrupted(self):
        self.assertEqual(next_prompt(None, "try again")["next"], "interrupted")
