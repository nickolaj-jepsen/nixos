"""The session rules as data: events in, rows out, no daemon."""

import unittest

from agent_hub.model import ASK_GRACE_MS, ONCE_MS, REGISTRY_GRACE_MS, Alerts, Session, ending, ordered

DONE = ending("Fixed the footer. It was too wide.")
FAILED = ending(failure="API error: overloaded")


def finished(outcome=DONE, now=100):
    session = Session(id="s")
    session.start_turn(now)
    session.end_turn(now + 10, outcome)
    return session


class EndingTest(unittest.TestCase):
    def test_a_turn_is_done_with_its_first_sentence_and_its_words(self):
        outcome = ending("**Fixed** the footer. It was too wide.\n\nWant the header too?")
        self.assertEqual((outcome["state"], outcome["summary"], outcome["jobs"]), ("done", "Fixed the footer.", 0))
        self.assertTrue(outcome["said"].endswith("Want the header too?"))

    def test_the_agents_error_fails_it(self):
        self.assertEqual(ending("Partial.", error=True)["state"], "failed")
        self.assertEqual((FAILED["state"], FAILED["summary"]), ("failed", "API error: overloaded"))

    def test_agent_work_in_flight_is_waited_on(self):
        outcome = ending("Started them.", tasks=[{"type": "subagent", "description": "Explore the hub"}, {"type": "shell"}])
        self.assertEqual((outcome["jobs"], outcome["doing"]), (2, "Explore the hub +1"))

    def test_a_shell_job_counts_only_when_the_words_wait_on_it(self):
        server = [{"type": "shell", "description": "npm run dev"}]
        self.assertEqual(ending("The dev server is up on :3000.", tasks=server)["jobs"], 0)
        self.assertEqual(ending("I'll wait for the build to finish.", tasks=server)["jobs"], 1)
        self.assertEqual(ending("Waiting on the build.", pending=2)["jobs"], 2)


class TurnTest(unittest.TestCase):
    def test_a_turn_works_then_shows_how_it_ended(self):
        session = Session(id="s")
        session.start_turn(0)
        self.assertEqual(session.state(1), "working")
        self.assertTrue(session.end_turn(10, DONE))
        row = session.row(13)
        self.assertEqual((row["state"], row["summary"], row["since"]), ("done", "Fixed the footer.", 10))
        self.assertEqual(row["said"], DONE["said"])

    def test_a_failed_turn_says_why(self):
        row = finished(FAILED).row(200)
        self.assertEqual((row["state"], row["reason"]), ("failed", "API error: overloaded"))

    def test_waiting_on_background_jobs_keeps_it_working(self):
        session = finished({**DONE, "jobs": 2})
        self.assertEqual(session.row(200)["doing"], "waiting on 2 background jobs")

    def test_history_keeps_the_last_three_endings(self):
        session = Session(id="s")
        for i in range(5):
            session.start_turn(i * 100)
            session.end_turn(i * 100 + 10, {**DONE, "summary": f"turn {i}"})
        self.assertEqual([h["did"] for h in session.row(1000)["history"]], ["turn 2", "turn 3", "turn 4"])

    def test_waiting_on_jobs_names_the_work_when_the_agent_did(self):
        session = finished({**DONE, "jobs": 1, "doing": "Explore the hub"})
        self.assertEqual(session.row(200)["reason"], "Explore the hub")

    def test_a_long_quiet_turn_is_still_working(self):
        session = Session(id="s")
        session.start_turn(0)
        self.assertEqual(session.state(24 * 3_600_000), "working")


class RegistryTest(unittest.TestCase):
    def test_registry_stands_in_for_a_start_and_an_interrupt(self):
        session = Session(id="s")
        self.assertEqual(session.observe("busy", None, 0, registry=True), "started")
        self.assertEqual(session.observe("idle", None, 10, registry=True), "interrupted")
        self.assertEqual(session.state(11), "idle")

    def test_registry_busy_leaves_the_last_ending_until_the_agent_had_its_chance(self):
        session = finished(DONE)
        self.assertEqual(session.observe("busy", None, 200, registry=True), "busy")
        self.assertIsNone(session.registry_turn(200 + REGISTRY_GRACE_MS - 1))
        self.assertEqual(session.state(200 + REGISTRY_GRACE_MS - 1), "done")
        self.assertEqual(session.registry_turn(200 + REGISTRY_GRACE_MS), 2)
        self.assertEqual(session.state(200 + REGISTRY_GRACE_MS), "working")

    def test_registry_going_idle_within_the_grace_starts_nothing(self):
        session = finished(DONE)
        session.observe("busy", None, 200, registry=True)
        session.observe("idle", None, 300, registry=True)
        self.assertIsNone(session.registry_turn(200 + REGISTRY_GRACE_MS))
        self.assertEqual(session.state(200 + REGISTRY_GRACE_MS), "done")

    def test_hook_adopts_the_turn_the_registry_started(self):
        session = Session(id="s")
        session.observe("busy", None, 0, registry=True)
        self.assertIsNone(session.start_turn(5))
        self.assertEqual(session.turn.n, 1)

    def test_hook_within_the_grace_is_the_only_start(self):
        session = finished(DONE)
        session.observe("busy", None, 200, registry=True)
        self.assertEqual(session.start_turn(205), 2)
        self.assertIsNone(session.registry_turn(200 + REGISTRY_GRACE_MS))
        self.assertEqual(session.turn.n, 2)

    def test_nothing_standing_needs_no_grace(self):
        session = finished(DONE)
        session.dismiss()
        self.assertEqual(session.observe("busy", None, 200, registry=True), "started")

    def test_stop_after_the_registry_went_idle_still_ends_the_turn(self):
        session = Session(id="s")
        session.start_turn(0)
        session.observe("busy", None, 1, registry=True)
        session.observe("idle", None, 10, registry=True)
        self.assertEqual(session.state(11), "idle")
        self.assertTrue(session.end_turn(12, DONE))
        self.assertEqual(session.row(13)["since"], 10)
        self.assertFalse(session.end_turn(14, DONE))

    def test_registry_still_busy_after_stop_starts_nothing(self):
        session = Session(id="s")
        session.observe("busy", None, 0, registry=True)
        session.start_turn(1)
        session.end_turn(10, DONE)
        session.observe("idle", None, 10)
        # The entry rescanned unchanged, its stamp still the turn's start.
        self.assertIsNone(session.observe("busy", None, 0, registry=True))
        self.assertFalse(session.turn.open)

    def test_a_modal_that_only_shows_something_changes_nothing(self):
        session = finished()
        session.observe("idle", None, 200, registry=True)
        session.observe("waiting", "dialog open", 210, registry=True)
        self.assertEqual(session.state(211), "done")
        session.observe("idle", None, 220, registry=True)
        self.assertEqual(session.state(221), "done")

    def test_hook_label_beats_the_registry_and_goes_when_the_dialog_closes(self):
        session = Session(id="s")
        session.start_turn(0)
        session.wait("Bash: rm -rf build", 5)
        session.observe("waiting", "dialog open", 6, registry=True)
        self.assertEqual(session.row(7)["reason"], "Bash: rm -rf build")
        session.observe("busy", None, 8, registry=True)
        self.assertEqual((session.state(9), session.dialog), ("working", ""))


class AsideTest(unittest.TestCase):
    """A turn a peer's message woke the session for."""

    def aside(self, session, outcome, at=300):
        session.start_aside(at)
        return session.end_aside(outcome, at + 10)

    def test_a_peers_turn_leaves_a_standing_ending_and_its_age(self):
        session = finished(DONE)
        before = session.row(200)
        session.start_aside(300)
        during = session.row(301)
        self.assertEqual((during["state"], during["since"]), ("done", before["since"]))
        self.assertIs(session.end_aside(DONE, 310), False)
        self.assertEqual(session.row(311), before)

    def test_a_session_with_nothing_standing_works_while_a_peer_is_answered(self):
        session = Session(id="s")
        session.start_aside(300)
        row = session.row(301)
        self.assertEqual((row["state"], row["since"]), ("working", 300))
        self.assertEqual(row["doing"], "answering another session")

    def test_a_peers_turn_that_only_finished_changes_nothing(self):
        session = finished(DONE)
        session.dismiss()
        self.assertIs(self.aside(session, ending("Replied.")), False)
        self.assertEqual(session.state(400), "idle")

    def test_a_peers_turn_that_failed_reaches_the_row(self):
        session = finished(DONE)
        self.assertIs(self.aside(session, FAILED), True)
        row = session.row(400)
        self.assertEqual((row["state"], row["since"], row["turn"]), ("failed", 310, 2))

    def test_a_message_mid_turn_is_part_of_that_turn(self):
        session = Session(id="s")
        session.start_turn(0)
        session.start_aside(5)
        self.assertIsNone(session.aside)

    def test_the_registry_going_idle_keeps_it_for_the_stop_that_may_follow(self):
        session = finished(DONE)
        session.start_aside(300)
        session.observe("idle", None, 305, registry=True)
        self.assertEqual(session.aside.ended, 305)
        self.assertEqual(session.state(306), "done")

    def test_the_registry_saying_busy_during_one_starts_no_turn(self):
        session = finished(DONE)
        session.start_aside(300)
        self.assertIsNone(session.observe("busy", None, 301, registry=True))
        self.assertIsNone(session.registry_turn(301 + REGISTRY_GRACE_MS))
        self.assertEqual(session.turn.n, 1)

    def test_a_peers_word_gives_back_what_a_registry_turn_replaced(self):
        session = finished(DONE)
        session.observe("busy", None, 300, registry=True)
        session.registry_turn(300 + REGISTRY_GRACE_MS)
        session.start_aside(300 + REGISTRY_GRACE_MS + 1)
        self.assertEqual((session.turn.n, session.state(300 + REGISTRY_GRACE_MS + 2)), (1, "done"))

    def test_a_session_with_only_an_aside_survives_saving(self):
        session = Session(id="s")
        session.start_aside(300)
        self.assertNotIn("aside", session.saved())


class DismissTest(unittest.TestCase):
    def test_dismissed_turn_is_idle_until_the_next_one_ends(self):
        session = finished()
        self.assertTrue(session.dismiss())
        self.assertEqual(session.state(200), "idle")
        session.start_turn(300)
        session.end_turn(310, DONE)
        self.assertEqual(session.state(330), "done")

    def test_nothing_to_dismiss_while_it_runs(self):
        session = Session(id="s")
        session.start_turn(0)
        self.assertFalse(session.dismiss())


class RowTest(unittest.TestCase):
    def test_persons_name_beats_the_derived_name_which_beats_the_folder(self):
        session = Session(id="s", cwd="/home/x/repo")
        self.assertEqual(session.row(0)["name"], "repo")
        session.derived = "repo-12"
        self.assertEqual(session.row(0)["name"], "repo-12")
        session.name = "mine"
        self.assertEqual(session.row(0)["name"], "mine")

    def test_saved_session_loads_as_it_was(self):
        session = finished(DONE)
        session.name = "fixture cleanup"
        again = Session.load(session.saved(), 999)
        self.assertEqual(again.row(1000), session.row(1000))

    def test_a_turn_a_restart_caught_open_comes_back_to_be_ended(self):
        session = Session(id="s")
        session.start_turn(0)
        again = Session.load(session.saved(), 999)
        self.assertTrue(again.turn.restored and again.turn.open)
        self.assertTrue(again.end_turn(1000, DONE))

    def test_a_turn_with_its_ending_comes_back_settled(self):
        self.assertFalse(Session.load(finished().saved(), 999).turn.restored)

    def test_an_ending_saved_before_the_gate_went_loads_as_done(self):
        saved = finished().saved()
        saved["label"] = "old label"
        saved["turn"].update(outcome={"state": "blocked", "ask": "ship it?", "summary": "Asked.", "jobs": 0}, reading=False, doing="")
        saved["history"] = [{"at": 110, "state": "needs-reply", "did": "Asked."}]
        again = Session.load(saved, 999)
        self.assertEqual((again.state(1000), again.history[0]["state"]), ("done", "done"))

    def test_order_puts_the_longest_waiting_attention_first_then_the_latest(self):
        rows = [{"state": s, "since": t} for s, t in
                [("idle", 5), ("done", 9), ("asking", 8), ("working", 7), ("asking", 3), ("idle", 6), ("failed", 1)]]
        self.assertEqual([(r["state"], r["since"]) for r in ordered(rows)],
                         [("asking", 3), ("asking", 8), ("failed", 1), ("done", 9), ("working", 7), ("idle", 6), ("idle", 5)])


def row(state="failed", since=100, window=None, rid="s"):
    return {"id": rid, "state": state, "since": since, "window": window}


class AlertsTest(unittest.TestCase):
    def pulse(self, alerts, now, focused=None, **fields):
        rows = [row(**fields)]
        alerts.update(rows, now, focused)
        return rows[0]["pulse"]

    def test_what_is_there_at_first_sight_is_known(self):
        alerts = Alerts()
        self.assertFalse(self.pulse(alerts, 200))
        self.assertTrue(self.pulse(alerts, 300, since=250))

    def test_a_failure_pulses_until_you_look_or_open_the_popout(self):
        alerts = Alerts({})
        self.assertTrue(self.pulse(alerts, 200))
        self.assertTrue(self.pulse(alerts, 100_000))
        self.assertFalse(self.pulse(alerts, 100_001, focused=7, window=7))
        self.assertFalse(self.pulse(alerts, 100_002))
        self.assertTrue(self.pulse(alerts, 100_003, since=100_003 - 1))
        alerts.seen()
        self.assertFalse(self.pulse(alerts, 100_004, since=100_003 - 1))

    def test_done_pulses_once(self):
        alerts = Alerts({})
        rows = [row("done")]
        self.assertEqual(alerts.update(rows, 200), ONCE_MS)
        self.assertTrue(rows[0]["pulse"])
        self.assertFalse(self.pulse(alerts, 200 + ONCE_MS, state="done"))

    def test_looking_at_it_as_it_ends_never_pulses(self):
        self.assertFalse(self.pulse(Alerts({}), 200, focused=7, window=7))

    def test_a_dialog_answered_within_the_grace_never_pulses(self):
        alerts = Alerts({})
        rows = [row("asking", since=100)]
        self.assertEqual(alerts.update(rows, 100 + 10), ASK_GRACE_MS - 10)
        self.assertFalse(rows[0]["pulse"])
        self.assertFalse(self.pulse(alerts, 100 + 20, state="working"))
        self.assertTrue(self.pulse(alerts, 500 + ASK_GRACE_MS, state="asking", since=500))

    def test_a_turn_known_across_a_restart_stays_quiet_and_one_that_ended_meanwhile_pulses(self):
        alerts = Alerts({})
        self.assertTrue(self.pulse(alerts, 200))
        again = Alerts(alerts.known)
        self.assertFalse(self.pulse(again, 300))
        self.assertTrue(self.pulse(again, 400, since=350))

    def test_a_turn_with_a_new_ending_pulses_even_in_the_same_state(self):
        alerts = Alerts({})
        self.pulse(alerts, 200)
        alerts.seen()
        self.assertTrue(self.pulse(alerts, 300, since=250))

    def test_a_row_gone_is_forgotten(self):
        alerts = Alerts({})
        alerts.update([row()], 200)
        alerts.update([], 300)
        self.assertEqual((alerts.known, alerts.pulsing), ({}, {}))


if __name__ == "__main__":
    unittest.main()
