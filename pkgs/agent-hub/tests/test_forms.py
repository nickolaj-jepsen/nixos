"""The answer form: its parser and steps as data, its store, the CLI with the hub down, and the
daemon and the bar sharing one draft with it."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from agent_hub import forms, formstore, links, protocol
from test_hub import Hub, has_session

PACKAGE = Path(__file__).resolve().parent.parent

# Turn endings in the shapes agents really write them, as seen across past Claude Code and pi
# sessions (mine's sessions.py); the wording is made up.

# grilling's format: lettered options, a blockquoted recommendation per question.
GRILLING_ROUND = """The bar and the funnel are independent, so this round asks both.

**Q1. Should every focus default to "worth doing, ranked by payoff per effort"?**

- **A.** Yes, one default for every kind. Big swings become an opt-in flag.
- **B.** Default by kind: features get "worth doing", refactors keep big swings.
- **C.** Add the bar as a second pick to the scope question.

> **Recommended:** A. A per-kind table is one more thing to keep in sync.

---

**Q2. Lower the per-generator target from 8–10 ideas to 5–6?**

> **Recommended:** Yes. Each run threw away about 85% of its candidates,
> and four generators still give 20–24.

---

**Q3. What should happen to `--quick`?**

- **A.** Drop it.
- **B.** Keep it as an alias."""

# Research and a table before the round; bodies hold numbered lists of their own.
ROUND_AFTER_RESEARCH = """I looked at how other tools keep ideas diverse:
- rotating methods from different categories;
- several critics rather than one.

1. Hotspots are churn × complexity.
2. Change coupling exposes hidden dependencies.

---

**Q19. Should the lenses come from this menu?**

| Lens | Asks |
|---|---|
| Hotspots | churn × size |
| Subtraction | what if X didn't exist |

The default trio per kind:
1. general: hotspots, subtraction, leverage;
2. perf: measure-first, hotspots.

> **Recommended:** Yes. It covers every kind of ask the mining found.

---

**Q25. Should the default be big swings, with `--quick` for the small bar?**

> **Recommended:** Yes. You said you'd almost always want big swings.

Sources: [one](https://example.com/one), [two](https://example.com/two)."""

# Numbered questions after a numbered list of ideas that asks nothing.
NUMBERED_QUESTIONS = """## Ideas, grouped by what they're for

**1. Reminding you what you have**
- A hint of the day, weighted by neglect.

**2. Repo state worth knowing**
- Other agents already running in this repo.

## Questions before I propose approaches

1. **What should it do for you?** Help you discover things, or warn you about state?

2. **Who should see it?**
   > **Recommended:** both. A short motd for you, the hints for the model.

3. **How much space should it take?**
   > **Recommended:** one to three lines, and nothing when there's nothing to say."""

# One question, its proposal in the bold title.
SINGLE_QUESTION = """**Q18: What should the agent do with each note? I propose: it folds the note into the plan and removes it.**

The alternative is to answer everything in chat and keep the file clean.

> **Recommended:** yes. The file is the conversation."""

# The legacy one-question format: a recommendation heading over bullets, then "Agree?".
MY_RECOMMENDATION = """**Q4. What happens when you tap an app while the VM is off?**

The VM dies with the app's process, so this is common.

**My recommendation:**
- **The app list is cached**, so the launcher works with the VM off.
- **A tap starts the VM**, with a splash while it boots.

Agree?"""

# Options with bold titles and prose after them; the lean comes in the closing text.
LEAN_TOWARD = """**Q10. The live interface: read-only, or can people steer?**

- **A. Read-only page (my recommendation for v1).** Steering stays in the tracker.
- **B. Interactive page:** steer, abort and approve from the UI.
- **C. Read-only plus a few buttons**, mirrored as tracker comments.

I lean toward **C**: it's A with the controls you'll want the first time an agent loops. Which do you want?"""

# ideate's chat summary before the one-line format: the route ends each item.
IDEATE_SUMMARY = """3 ideas, saved to `~/notes/ideas/IDEAS.md`

1. Sample clocks throughout each bench run
   Explains the biggest unexplained number.
   Small, build it.
2. **Bench real clients by replaying their frames**
   Synthetic content already misled one idea.
   Medium, brainstorm first.
3. Keep fence waits outside the session lock
   The main thread takes the same lock on every touch.
   Small, grill first.

- The verifier rated idea 3 weak; I kept it, ranked last.

Start with 1: its result decides whether idea 3 is worth doing."""

# The one-line summary ideate and mine share.
MINE_SUMMARY = """2 findings from 4 runs, saved to `~/notes/FINDINGS.md`

1. The default bar cuts the ideas you act on · 2/3 · S · build
2. The funnel is wide and slow for what survives · 3/3 · M · /grill-me

**Top pick: 1.** Make "worth doing" the default bar."""

# A numbered list that asks nothing.
PLAIN_LIST = """Done. What changed:

1. The parser takes `Q` labels and numbers.
2. The review screen fills the prompt.

Tests pass."""

# A round's format quoted inside a fence is not a round.
FENCED_FORMAT = "Format a round like so:\n\n```\n**Q1. <question>**\n\n> **Recommended:** <answer>\n```\n\nThat's the whole format."


def shape(form):
    """`label[option keys*recommended key]`, a bare `*` for a recommendation naming no option."""
    if form is None:
        return "null"

    def one(item):
        keys = ("," if form["kind"] == "picks" else "").join(option["key"] for option in item["options"])
        if "recommendedOption" in item:
            return f"{item['label']}[{keys}*{item['options'][item['recommendedOption']]['key']}]"
        return f"{item['label']}[{keys}{'*' if 'recommended' in item else ''}]"

    return " ".join([form["kind"], *map(one, form["items"])])


def steps(form, *actions, start=None):
    draft = start or forms.new_draft(form)
    for action in actions:
        draft = forms.apply(form, draft, action)
    return draft


def pick(entry):
    return {"do": "pick", "entry": entry}


def toggle(entry):
    return {"do": "toggle", "entry": entry}


FORWARD = {"do": "forward"}


class ParseTest(unittest.TestCase):
    def test_each_ending_parses_to_its_shape(self):
        for text, expected in (
            (GRILLING_ROUND, "round Q1[ABC*A] Q2[*] Q3[AB]"),
            (ROUND_AFTER_RESEARCH, "round Q19[*] Q25[*]"),
            (NUMBERED_QUESTIONS, "round 1[] 2[*] 3[*]"),
            (SINGLE_QUESTION, "round Q18[*]"),
            (MY_RECOMMENDATION, "round Q4[*]"),
            (LEAN_TOWARD, "round Q10[ABC*C]"),
            (IDEATE_SUMMARY, "picks 1[build*build] 2[build,/brainstorm*/brainstorm] 3[build,/grill-me*/grill-me]"),
            (MINE_SUMMARY, "picks 1[build*build] 2[build,/grill-me*/grill-me]"),
            (PLAIN_LIST, "null"),
            (FENCED_FORMAT, "null"),
        ):
            self.assertEqual(shape(forms.parse(text)), expected)

    def test_a_question_keeps_its_context_and_drops_what_the_form_draws_itself(self):
        q1, q2, _ = forms.parse(GRILLING_ROUND)["items"]
        self.assertEqual(q1["title"], 'Should every focus default to "worth doing, ranked by payoff per effort"?')
        self.assertEqual(q1["options"][1]["text"], 'Default by kind: features get "worth doing", refactors keep big swings.')
        self.assertEqual(q1["body"], "")
        self.assertEqual(q2["recommended"], "Yes. Each run threw away about 85% of its candidates, and four generators still give 20–24.")
        first = forms.parse(NUMBERED_QUESTIONS)["items"][0]
        self.assertEqual(first["title"], "What should it do for you?")
        self.assertEqual(first["body"], "Help you discover things, or warn you about state?")
        self.assertIn("| Hotspots | churn × size |", forms.parse(ROUND_AFTER_RESEARCH)["items"][0]["body"])

    def test_a_label_bolded_apart_from_its_title_keeps_the_whole_title(self):
        options = "- **A.** Yes\n- **B.** No\n\n"
        form = forms.parse(f"**Q1.** **Should X?**\n\n{options}**Q2.** Use **bold** word here?\n\n{options}")
        self.assertEqual([item["title"] for item in form["items"]], ["Should X?", "Use bold word here?"])

    def test_a_bold_option_title_leaves_its_prose_as_detail(self):
        a, b, _ = forms.parse(LEAN_TOWARD)["items"][0]["options"]
        self.assertEqual(a["text"], "Read-only page (my recommendation for v1).")
        self.assertEqual(a["detail"], "Steering stays in the tracker.")
        self.assertEqual(b["text"], "Interactive page:")

    def test_a_pick_keeps_its_title_apart_from_its_fields(self):
        one, two = forms.parse(MINE_SUMMARY)["items"]
        self.assertEqual(one["title"], "The default bar cuts the ideas you act on")
        self.assertEqual(one["body"], "2/3 · S · build")
        self.assertEqual(forms.parse(IDEATE_SUMMARY)["items"][1]["title"], "Bench real clients by replaying their frames")
        self.assertEqual(two["recommended"], "route it to /grill-me")


class StepTest(unittest.TestCase):
    def test_answering_steps_through_the_items_to_the_review(self):
        form = forms.parse(GRILLING_ROUND)
        draft = steps(form, pick(1), FORWARD)
        self.assertEqual(draft["step"], 1)
        draft = forms.apply(form, draft, pick(0))
        draft = forms.apply(form, draft, FORWARD)
        # Q3 recommends nothing, so its entries are its options and a write-in.
        draft = forms.apply(form, draft, {"do": "write", "text": "  keep it  "})
        self.assertTrue(forms.is_review(form, draft))
        self.assertEqual(forms.go(form, draft, 99)["step"], 3)
        self.assertEqual(forms.go(form, draft, -1)["step"], 0)
        self.assertEqual(forms.reply(form, draft), "Q1: B\nQ2: yes\nQ3: keep it")

    def test_picking_a_write_in_records_nothing_until_it_is_written(self):
        form = forms.parse(GRILLING_ROUND)
        write_in = len(forms.entries(form["items"][0])) - 1
        self.assertEqual(steps(form, pick(write_in)), forms.new_draft(form))

    def test_a_round_of_recommendations_collapses_to_yes_unless_something_else_is_said(self):
        form = forms.parse(ROUND_AFTER_RESEARCH)
        draft = steps(form, pick(0), FORWARD, pick(0), FORWARD)
        self.assertEqual(forms.reply(form, draft), "yes")
        noted = forms.apply(form, draft, {"do": "note", "text": "also look at subtraction"})
        self.assertEqual(forms.reply(form, noted), "Q19: yes\nQ25: yes\nOverall: also look at subtraction")

    def test_a_skipped_question_stays_out_of_the_reply_and_a_note_rides_on_its_answer(self):
        form = forms.parse(GRILLING_ROUND)
        # Picking the recommended letter is still the recommendation.
        draft = steps(form, pick(0), {"do": "note", "text": "but keep the flag"}, FORWARD, {"do": "skip"}, pick(1))
        self.assertEqual(forms.reply(form, draft), "Q1: A\n    Note: but keep the flag\nQ3: B")
        # A note with no answer says so, so it can't read as a write-in.
        alone = steps(form, {"do": "note", "text": "depends on Q3"})
        self.assertEqual(forms.reply(form, alone), "Q1: no answer yet\n    Note: depends on Q3")
        self.assertEqual(forms.reply(form, forms.new_draft(form)), "")

    def test_picks_group_the_builds_and_route_the_rest(self):
        form = forms.parse(IDEATE_SUMMARY)
        draft = steps(form, pick(0), FORWARD, pick(0), FORWARD, pick(1), FORWARD)
        self.assertEqual(forms.reply(form, draft), "do 1, 2\n3 → /grill-me")
        other = steps(form, pick(0), {"do": "note", "text": "measure first"}, FORWARD, {"do": "write", "text": "merge with 3"})
        self.assertEqual(forms.reply(form, other), "do 1\n    Note: measure first\n2: merge with 3")

    def test_going_on_finds_the_next_item_unanswered_and_then_the_review(self):
        form = forms.parse(GRILLING_ROUND)
        answer = lambda entry: [pick(entry), {"do": "next"}]
        draft = steps(form, FORWARD, *answer(0))
        self.assertEqual(draft["step"], 2)
        # Nothing is left after Q3, so it looks from the top; with nothing there either, the review.
        draft = forms.apply(form, draft, {"do": "write", "text": "keep"})
        self.assertEqual(draft["step"], 0)
        self.assertTrue(forms.is_review(form, steps(form, *answer(1), start=draft)))
        # A pick that stayed for its note goes on the same way; the review has nowhere to go.
        self.assertEqual(steps(form, pick(0), {"do": "next"})["step"], 1)
        self.assertTrue(forms.is_review(form, steps(form, {"do": "review"}, {"do": "next"})))
        # An empty write-in clears and stays.
        self.assertEqual(steps(form, {"do": "write", "text": " "})["step"], 0)

    def test_several_options_toggle_into_one_answer(self):
        form = forms.parse(GRILLING_ROUND)
        draft = steps(form, pick(2), toggle(0))
        self.assertEqual(draft["step"], 0)
        view = forms.view(form, draft)
        self.assertEqual([e["isChosen"] for e in view["item"]["entries"]], [True, False, True, False])
        self.assertTrue(view["item"]["isSeveral"])
        self.assertEqual(forms.reply(form, draft), "Q1: A, C")
        self.assertTrue(view["review"][0]["shown"].startswith("A, C: "))
        self.assertEqual(forms.reply(form, steps(form, toggle(0), toggle(0))), "")
        # A write-in, or a pick list's routes, are not for toggling.
        self.assertEqual(steps(form, toggle(3)), forms.new_draft(form))
        picks = forms.parse(IDEATE_SUMMARY)
        self.assertEqual(steps(picks, FORWARD, toggle(0)), steps(picks, FORWARD))

    def test_a_recommendation_naming_several_letters_is_accepted_as_all_of_them(self):
        options = "".join(f"- **{letter}.** Item {letter}.\n" for letter in "ABCDEF")
        for said, keys in (("A, B and D now; C is cosmetic and E can wait.", "A, B, D"),
                           ("A through C now; F goes to later.", "A, B, C"),
                           ("**A** and **C**.", "A, C")):
            form = forms.parse(f"**Q1. Which go in?**\n\n{options}\n> **Recommended:** {said}\n")
            item = forms.view(form, forms.new_draft(form))["item"]
            self.assertTrue(item["isSeveral"] and item["canAccept"])
            self.assertEqual("".join(e["text"][0] for e in item["entries"] if e["isRecommended"]), keys.replace(", ", ""))
            self.assertEqual(forms.reply(form, steps(form, toggle(0))), "Q1: A")
            self.assertEqual(forms.reply(form, steps(form, {"do": "accept"})), "yes")
            self.assertEqual(forms.reply(form, steps(form, {"do": "accept"}, toggle(5))), f"Q1: {keys}, F")
        # One letter is still one pick, and a sentence that starts on "A" names none.
        single = forms.parse(GRILLING_ROUND)
        self.assertEqual(forms.reply(single, steps(single, {"do": "accept"}))[:5], "Q1: A")
        self.assertFalse(forms.view(single, forms.new_draft(single))["item"]["isSeveral"])
        self.assertEqual(steps(single, FORWARD, FORWARD, {"do": "accept"}), steps(single, FORWARD, FORWARD))

    def test_what_cannot_apply_changes_nothing_and_an_unknown_word_is_refused(self):
        form = forms.parse(GRILLING_ROUND)
        self.assertEqual(steps(form, pick(99)), forms.new_draft(form))
        with self.assertRaises(ValueError):
            steps(form, {"do": "explode"})


class ViewTest(unittest.TestCase):
    def test_says_all_a_surface_draws_of_an_item(self):
        form = forms.parse(GRILLING_ROUND)
        view = forms.view(form, steps(form, pick(1)))
        self.assertEqual((view["title"], view["count"], view["answered"], view["isReview"]), ("Answer 3 questions", 3, 1, False))
        entries = view["item"]["entries"]
        self.assertEqual([e["kind"] for e in entries], ["option", "option", "option", "write"])
        self.assertEqual(entries[1]["text"], 'B. Default by kind: features get "worth doing", refactors keep big swings.')
        self.assertEqual([e["isRecommended"] for e in entries], [True, False, False, False])
        self.assertEqual([e["isChosen"] for e in entries], [False, True, False, False])
        self.assertEqual(view["item"]["start"], 1)

    def test_starts_on_the_recommendation_and_words_a_review(self):
        form = forms.parse(GRILLING_ROUND)
        self.assertEqual(forms.view(form, forms.new_draft(form))["item"]["start"], 0)
        second = forms.view(form, steps(form, FORWARD))["item"]
        self.assertEqual(second["entries"][0]["text"][:4], "Yes:")
        review = forms.view(form, steps(form, pick(1), FORWARD, FORWARD, {"do": "write", "text": "keep"}, {"do": "review"}))
        self.assertIsNone(review["item"])
        self.assertTrue(review["isReview"])
        self.assertEqual([r["isAnswered"] for r in review["review"]], [True, False, True])
        self.assertEqual(review["review"][2]["shown"], '"keep"')

    def test_shows_why_an_option_is_recommended(self):
        form = forms.parse(GRILLING_ROUND)
        first = forms.view(form, forms.new_draft(form))["item"]
        self.assertTrue(first["recommended"].startswith("A. "))
        # With no options the recommendation is the accept entry, not said twice.
        second = forms.view(form, steps(form, FORWARD))["item"]
        self.assertEqual(second["recommended"], "")

    def test_a_recommendation_beside_options_is_said_and_never_an_entry(self):
        text = "**Q1. Which go in?**\n\n- **A.** Log.\n- **B.** Cooldown.\n- **C.** Canary.\n\n> **Recommended:** A and B now, C later.\n"
        item = forms.view(*(lambda form: (form, forms.new_draft(form)))(forms.parse(text)))["item"]
        self.assertEqual([e["kind"] for e in item["entries"]], ["option", "option", "option", "write"])
        self.assertEqual(item["recommended"], "A and B now, C later.")
        self.assertTrue(item["canSeveral"])

    def test_reads_a_pick_said_in_passing(self):
        options = "- **A.** Flatten it.\n- **B.** Keep the grouping.\n"
        for text in (f"**Q1. Which?**\n\nI'd go with A, since B buys nothing.\n\n{options}",
                     "**Q1. Which?**\n\n- **A.** Flatten it (my pick, and the smaller change).\n- **B.** Keep it.\n"):
            self.assertEqual(forms.parse(text)["items"][0]["recommendedOption"], 0)

    def test_is_what_the_protocol_says_it_is(self):
        form = forms.parse(GRILLING_ROUND)
        for draft in (forms.new_draft(form), steps(form, {"do": "review"})):
            protocol._check(forms.view(form, draft), protocol.FORM_VIEW, "view")


class StoreTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "forms"

    def test_a_new_round_replaces_the_form_and_the_same_one_keeps_its_answers(self):
        first = formstore.offer(self.root, "s", GRILLING_ROUND)
        formstore.step(self.root, "s", pick(1), first["id"])
        self.assertEqual(formstore.offer(self.root, "s", GRILLING_ROUND)["answered"], 1)
        self.assertEqual(formstore.offer(self.root, "s", MINE_SUMMARY)["answered"], 0)

    def test_a_turn_that_asks_nothing_leaves_the_round_waiting(self):
        formstore.offer(self.root, "s", GRILLING_ROUND)
        formstore.step(self.root, "s", pick(1))
        self.assertEqual(formstore.offer(self.root, "s", PLAIN_LIST)["answered"], 1)
        self.assertIsNone(formstore.offer(self.root, "other", PLAIN_LIST))

    def test_a_step_aimed_at_an_older_form_lands_on_nothing(self):
        old = formstore.offer(self.root, "s", GRILLING_ROUND)["id"]
        formstore.offer(self.root, "s", MINE_SUMMARY)
        self.assertEqual(formstore.step(self.root, "s", pick(0), old)["answered"], 0)

    def test_a_reply_is_handed_over_once(self):
        formstore.offer(self.root, "s", GRILLING_ROUND)
        self.assertIsNone(formstore.deliver(self.root, "s", False), "nothing is answered yet")
        formstore.step(self.root, "s", pick(1))
        self.assertTrue(formstore.deliver(self.root, "s", False)["pending"])
        taken = formstore.sync(self.root, "s")
        self.assertEqual((taken["delivery"]["text"], taken["delivery"]["submit"]), ("Q1: B", False))
        self.assertFalse(taken["view"]["pending"])
        self.assertIsNone(formstore.sync(self.root, "s")["delivery"])

    def test_a_reply_taken_to_send_drops_the_form(self):
        formstore.offer(self.root, "s", GRILLING_ROUND)
        formstore.step(self.root, "s", pick(1))
        formstore.deliver(self.root, "s", True)
        self.assertTrue(formstore.sync(self.root, "s")["delivery"]["submit"])
        self.assertIsNone(formstore.view_of(self.root, "s"))

    def test_a_reply_nobody_took_in_time_is_never_handed_over(self):
        formstore.offer(self.root, "s", GRILLING_ROUND)
        formstore.step(self.root, "s", pick(1))
        formstore.deliver(self.root, "s", True)
        path = formstore.path_of(self.root, "s")
        record = json.loads(path.read_text())
        record["delivery"]["at"] -= formstore.DELIVERY_TTL_MS + 1
        path.write_text(json.dumps(record))
        self.assertFalse(formstore.view_of(self.root, "s")["pending"])
        taken = formstore.sync(self.root, "s")
        self.assertIsNone(taken["delivery"])
        self.assertEqual(taken["view"]["answered"], 1)

    def test_an_id_that_could_leave_the_folder_names_no_form(self):
        for session in ("../escape", "host:uuid", "", ".hidden"):
            with self.assertRaises(ValueError):
                formstore.path_of(self.root, session)
            self.assertIsNone(formstore.view_of(self.root, session))

    def test_only_a_form_left_alone_for_a_week_is_forgotten(self):
        formstore.offer(self.root, "old", GRILLING_ROUND)
        formstore.offer(self.root, "new", GRILLING_ROUND)
        now = formstore.path_of(self.root, "new").stat().st_mtime
        os.utime(formstore.path_of(self.root, "old"), (now - 8 * 86400, now - 8 * 86400))
        formstore.prune(self.root, now * 1000)
        self.assertEqual([session for session, _ in formstore.listing(self.root)], ["new"])


class CliWithoutHubTest(unittest.TestCase):
    """`agent-hub answer` with no daemon: its socket's folder doesn't even exist."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.env = dict(os.environ, XDG_RUNTIME_DIR=f"{tmp.name}/run", XDG_STATE_HOME=f"{tmp.name}/state",
                        AGENT_HUB_CONFIG=f"{tmp.name}/none.json")

    def run_cli(self, *args, stdin="", check=True):
        return subprocess.run([sys.executable, "-m", "agent_hub", "answer", *args], env=self.env, cwd=PACKAGE, input=stdin,
                              text=True, capture_output=True, check=check, timeout=10)

    def test_a_round_goes_from_offer_to_a_handed_over_reply(self):
        view = json.loads(self.run_cli("offer", "--session", "s", stdin=GRILLING_ROUND).stdout)
        self.assertEqual(view["title"], "Answer 3 questions")
        self.run_cli("step", "--session", "s", "--form", view["id"], json.dumps(pick(1)))
        self.assertEqual(json.loads(self.run_cli("show", "--session", "s").stdout)["reply"], "Q1: B")
        self.assertIn("Answer 3 questions\t1 answered\tQ1: B", self.run_cli("show").stdout)
        self.run_cli("deliver", "--session", "s", "--send")
        taken = json.loads(self.run_cli("sync", "--session", "s").stdout)
        self.assertEqual((taken["delivery"]["text"], taken["delivery"]["submit"], taken["view"]), ("Q1: B", True, None))

    def test_parse_says_by_its_exit_code_whether_the_text_asks_anything(self):
        self.assertEqual(json.loads(self.run_cli("parse", stdin=MINE_SUMMARY).stdout)["kind"], "picks")
        self.assertEqual(self.run_cli("parse", stdin=PLAIN_LIST, check=False).returncode, 1)

    def test_a_bad_session_or_action_fails_with_a_reason(self):
        self.assertIn("no form can belong", self.run_cli("show", "--session", "../x", check=False).stderr)
        self.run_cli("offer", "--session", "s", stdin=GRILLING_ROUND)
        self.assertIn("no such action", self.run_cli("step", "--session", "s", '{"do":"explode"}', check=False).stderr)


class HubFormTest(unittest.TestCase):
    """The daemon and the CLI on one store, as the bar and an agent's TUI share a draft."""

    SID = "11111111-2222-4333-8444-555555555555"

    def setUp(self):
        self.hub = Hub()
        self.addCleanup(self.hub.stop)
        self.proc = self.hub.process()
        self.hub.write_session(self.proc.pid, self.SID, status="idle")
        self.bar = self.hub.subscribe()
        self.bar.wait(has_session(self.SID))

    def cli(self, *args, stdin=""):
        return json.loads(self.hub.command("answer", *args, "--session", self.SID, stdin=stdin).stdout)

    def form(self, predicate=lambda form: True):
        """The session's `answer` in the first state that satisfies `predicate`."""
        message = self.bar.wait(has_session(self.SID, lambda s: s.get("answer") is not None and predicate(s["answer"])))
        return next(s for s in message["sessions"] if s["id"] == self.SID)["answer"]

    def test_the_bar_sees_what_the_cli_does_and_the_cli_what_the_bar_does(self):
        view = self.cli("offer", stdin=GRILLING_ROUND)
        self.assertEqual(self.form()["id"], view["id"])
        self.bar.send(op="form-step", session=self.SID, form=view["id"], action=pick(1))
        self.assertEqual(self.form(lambda f: f["answered"] == 1)["reply"], "Q1: B")
        self.assertEqual(self.cli("show")["reply"], "Q1: B")
        self.hub.command("answer", "step", "--session", self.SID, '{"do":"review"}')
        self.assertTrue(self.form(lambda f: f["isReview"])["isReview"])

    def test_a_reply_from_the_bar_reaches_the_tui_and_clears_the_row(self):
        view = self.cli("offer", stdin=GRILLING_ROUND)
        self.bar.send(op="form-step", session=self.SID, form=view["id"], action=pick(1))
        self.form(lambda f: f["answered"] == 1)
        self.bar.send(op="form-deliver", session=self.SID, form=view["id"], submit=True)
        self.form(lambda f: f["pending"])
        taken = self.cli("sync")
        self.assertEqual((taken["delivery"]["text"], taken["delivery"]["submit"]), ("Q1: B", True))
        self.bar.wait(has_session(self.SID, lambda s: "answer" not in s))

    def test_a_form_opened_with_the_hub_down_shows_when_it_comes_back(self):
        self.hub.kill()
        self.cli("offer", stdin=GRILLING_ROUND)
        self.hub.socket.unlink()
        self.hub.start()
        self.bar = self.hub.connect()
        self.bar.send(op="subscribe")
        self.assertEqual(self.form()["title"], "Answer 3 questions")

    def test_a_form_op_for_another_hosts_session_is_an_error_not_a_write(self):
        self.bar.send(op="form-step", session="laptop:" + self.SID, form="x", action=pick(0))
        self.assertIn("no form can belong", self.bar.wait(lambda m: m["type"] == "error")["error"])


class LinkTest(unittest.TestCase):
    """A reply can start anything, so forms stay on the host: nothing of one crosses a link."""

    def test_no_form_op_passes_an_attach_even_with_control(self):
        for op in (
            "form-offer",
            "form-step",
            "form-deliver",
            "form-sync",
            "form-drop",
            "form-changed",
        ):
            line = json.dumps({"op": op, "session": HubFormTest.SID, "form": "x", "submit": True, "action": pick(0)})
            self.assertIsNone(links.attach_filter(line, True))

    def test_a_remote_row_loses_its_form(self):
        row = {"id": HubFormTest.SID, "state": "needs-reply", "answer": {"id": "x"}}
        self.assertNotIn("answer", links.clean_row("laptop", row))


if __name__ == "__main__":
    unittest.main()
