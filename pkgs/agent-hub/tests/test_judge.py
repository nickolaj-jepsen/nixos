"""The gate's candidate and what the model reads, as data."""

import unittest

from agent_hub import claude, judge

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


class EndingTest(unittest.TestCase):
    def outcome(self, ending, said="Keep the fixture?", sure="high"):
        digest = {"said": said}
        fields = judge.parse(f"ends: {ending}\nsure: {sure}\nask: keep it?\ndid: Did it.\n")
        return judge.outcome(fields, judge.heuristic(digest), digest)

    def test_an_ending_can_call_you_with_no_question_in_the_words(self):
        found = self.outcome("needs-hands", said="Plug it in over USB.")
        self.assertEqual((found["state"], found["kind"], found["ask"]), ("blocked", "needs-hands", "keep it?"))

    def test_a_sure_ending_quiets_a_question(self):
        found = self.outcome("landed-optional", said="Merged to main. Want me to push?")
        self.assertEqual((found["state"], found["kind"], found["ask"]), ("done", "", ""))

    def test_an_unsure_ending_doesnt_quiet_a_question(self):
        self.assertEqual(self.outcome("finished", sure="low")["state"], "blocked")

    def test_an_unsure_ending_with_no_question_stays_quiet(self):
        self.assertEqual(self.outcome("finished", said="All done.", sure="low")["state"], "done")

    def test_an_ending_that_calls_nobody_doesnt_label_the_row(self):
        found = self.outcome("finished", sure="low")
        self.assertEqual((found["state"], found["kind"]), ("blocked", ""))

    def test_case_is_not_the_models_to_get_right(self):
        self.assertEqual(self.outcome("Ready-To-Land")["kind"], "ready-to-land")

    def test_an_ending_it_doesnt_know_is_dropped_and_the_candidate_stands(self):
        found = self.outcome("urgent")
        self.assertEqual((found["kind"], found["state"]), ("", "blocked"))

    def test_a_model_that_only_gives_a_state_still_counts(self):
        digest = {"said": "Want me to add more?"}
        self.assertEqual(judge.outcome(judge.parse("state: done\n"), judge.heuristic(digest), digest)["state"], "done")


class LandedTest(unittest.TestCase):
    def digest(self, *lines, failed=False, **rest):
        commands = [(str(n), line[:48], line) for n, line in enumerate(lines)]
        return {**claude.assemble([], [], commands, {str(n): failed for n in range(len(lines))}, ""), **rest}

    def test_a_landing_counts_whatever_the_branch(self):
        for line in ("wt land", "wt land --green x", "gh pr merge 12 --squash", "git push origin main",
                     "git -C /r push origin master"):
            self.assertTrue(judge.landed(self.digest(line)), line)

    def test_a_commit_counts_only_on_the_default_branch(self):
        self.assertTrue(judge.landed(self.digest("git commit -m x", branch="main")))
        self.assertTrue(judge.landed(self.digest("git commit -m x", on_branch="main")))
        self.assertFalse(judge.landed(self.digest("git commit -m x", branch="feature")))
        self.assertFalse(judge.landed(self.digest("git commit -m x")))

    def test_a_push_elsewhere_or_a_failed_one_doesnt(self):
        self.assertFalse(judge.landed(self.digest("git push origin feature")))
        self.assertFalse(judge.landed(self.digest("git push origin feature/main-fix")))
        self.assertFalse(judge.landed(self.digest("wt land", failed=True)))

    def test_opening_a_pr_doesnt(self):
        for line in ("wt land --pr x", "wt land --draft --title y", "wt land --pr --branch feat/z"):
            self.assertFalse(judge.landed(self.digest(line)), line)

    def test_a_command_counts_past_what_the_row_shows(self):
        long_add = "git add modules/programs/agent-hub.nix pkgs/agent-hub/agent_hub/hub.py && git commit -m x"
        self.assertTrue(judge.landed(self.digest(long_add, branch="main")))
        self.assertTrue(judge.landed(self.digest("git add x\ngit commit -m y", branch="main")))

    def test_a_landing_early_in_a_long_turn_still_counts(self):
        self.assertTrue(judge.landed(self.digest("wt land", *[f"echo {n}" for n in range(20)])))

    def test_the_model_is_told(self):
        self.assertIn("landed: yes", judge.render(self.digest("wt land"), {}, True))
        self.assertIn("landed: no", judge.render(self.digest("ls"), {}, True))


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
