"""The gate's candidate and what the model reads, as data."""

import unittest

from agent_hub import judge

ROUND = """I've turned these into decisions.

**Q1. Store it in SQLite?**

- **A.** SQLite
- **B.** A flat file

> **Recommended:** A, since it is already a dependency.

---

**Q2. Ship it behind a flag?**

> **Recommended:** no, nobody else runs this."""


class CandidateTest(unittest.TestCase):
    def ask(self, said):
        return judge.heuristic({"said": said})["ask"]

    def test_a_question_at_the_end_is_an_ask(self):
        self.assertEqual(self.ask("Rebased.\n\nWant me to push?"), "Want me to push?")

    def test_a_list_of_questions_ending_on_something_else_is_an_ask(self):
        self.assertTrue(self.ask(ROUND))

    def test_a_request_with_no_question_mark_is_an_ask(self):
        self.assertTrue(self.ask("Built it.\n\nLet me know when the reboot is done."))

    def test_words_with_no_ask_are_none(self):
        self.assertEqual(self.ask("Fixed the footer and the tests pass."), "")

    def test_a_question_inside_a_code_block_is_no_ask(self):
        self.assertEqual(self.ask("Done:\n\n```\nread -p 'continue?'\n```"), "")


class AskKindTest(unittest.TestCase):
    def outcome(self, kind, said="Keep the fixture?", state="blocked"):
        digest = {"said": said}
        return judge.outcome(judge.parse(f"state: {state}\nask: keep it?\nkind: {kind}\n"), judge.heuristic(digest), digest)

    def test_a_tag_it_knows_is_kept(self):
        for kind in judge.ASK_KINDS:
            self.assertEqual(self.outcome(kind)["kind"], kind)

    def test_case_is_not_the_models_to_get_right(self):
        self.assertEqual(self.outcome("Do Something")["kind"], "do something")

    def test_a_tag_it_doesnt_is_dropped_and_the_ask_stands(self):
        found = self.outcome("urgent")
        self.assertEqual((found["kind"], found["state"]), ("", "blocked"))

    def test_only_an_ask_has_one(self):
        self.assertEqual(self.outcome("decide", state="done")["kind"], "")


class EstimateTest(unittest.TestCase):
    def test_minutes_and_a_note(self):
        self.assertEqual(judge.parse_estimate("left: 20\nnote: 31/40 built"), {"left": 20, "note": "31/40 built"})

    def test_it_may_not_know(self):
        self.assertEqual(judge.parse_estimate("left:\nnote: empty"), {"left": None, "note": ""})

    def test_a_model_that_adds_a_word_still_counts(self):
        self.assertEqual(judge.parse_estimate("**left**: about 20 minutes\nnote: ")["left"], 20)

    def test_no_answer_is_none(self):
        self.assertIsNone(judge.parse_estimate("I can't say."))

    def test_it_reads_the_past_and_the_output_only_when_there_are_any(self):
        bare = judge.estimate_prompt("just build", 34, [], "")
        self.assertNotIn("earlier runs", bare)
        self.assertNotIn("output", bare)
        full = judge.estimate_prompt("just build", 34, [36, 40], "31/40 built")
        self.assertIn("36, 40", full)
        self.assertIn("31/40 built", full)


class RenderTest(unittest.TestCase):
    def test_a_long_message_keeps_its_start_and_its_end(self):
        said = "Q1 keep it? " + "x" * 10_000 + " the end"
        text = judge.render({"said": said}, {}, True)
        self.assertIn("Q1 keep it?", text)
        self.assertIn("the end", text)
        self.assertLess(len(text), judge.SAID_CHARS + 200)

    def test_a_turn_answering_a_peer_says_so(self):
        self.assertIn("another agent session", judge.render({"said": "Hi.", "peer": True}, {}, True))
        self.assertNotIn("another agent session", judge.render({"said": "Hi."}, {}, True))

    def test_naming_your_prompt_after_a_peers_turn_doesnt_mention_it(self):
        digest = {"requests": ["next thing"]}
        self.assertEqual(judge.render({**digest, "peer": True}, {}, False), judge.render(digest, {}, False))
