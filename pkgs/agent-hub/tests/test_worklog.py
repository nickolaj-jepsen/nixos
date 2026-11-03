"""What the work log derives from your next prompt."""

import unittest

from agent_hub.worklog import next_prompt

ASKED = {"state": "blocked", "reply": "keep it"}
DONE = {"state": "done", "reply": ""}


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
