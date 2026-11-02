"""The session rules as data: events in, rows out, no daemon."""

import unittest

from agent_hub.model import ASK_GRACE_MS, ONCE_MS, Alerts, Session, ordered

DONE = {"state": "done", "ask": "", "reply": "", "summary": "Fixed the footer.", "jobs": 0}
BLOCKED = {"state": "blocked", "ask": "keep the fixture?", "reply": "yes", "summary": "Asked.", "jobs": 0}


def finished(outcome=DONE, now=100):
    session = Session(id="s")
    n = session.start_turn(now)
    session.end_turn(now + 10)
    session.read(n, outcome, now + 20)
    return session


class TurnTest(unittest.TestCase):
    def test_a_turn_works_then_shows_how_it_ended(self):
        session = Session(id="s")
        n = session.start_turn(0)
        self.assertEqual(session.state(1), "working")
        self.assertEqual(session.end_turn(10), n)
        session.reading(n, True)
        self.assertEqual(session.row(11)["doing"], "reading the turn")
        session.read(n, BLOCKED, 12)
        row = session.row(13)
        self.assertEqual((row["state"], row["ask"], row["reply"], row["since"]), ("needs-reply", "keep the fixture?", "yes", 10))

    def test_a_reading_that_lands_after_the_next_turn_started_is_dropped(self):
        session = Session(id="s")
        n = session.start_turn(0)
        session.end_turn(10)
        session.start_turn(20)
        self.assertFalse(session.read(n, DONE, 30))
        self.assertEqual(session.state(31), "working")

    def test_waiting_on_background_jobs_keeps_it_working(self):
        session = finished({**DONE, "jobs": 2})
        self.assertEqual(session.row(200)["doing"], "waiting on 2 background jobs")

    def test_history_keeps_the_last_three_endings(self):
        session = Session(id="s")
        for i in range(5):
            n = session.start_turn(i * 100)
            session.end_turn(i * 100 + 10)
            session.read(n, {**DONE, "summary": f"turn {i}"}, i * 100 + 20)
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

    def test_hook_adopts_the_turn_the_registry_started(self):
        session = Session(id="s")
        session.observe("busy", None, 0, registry=True)
        self.assertIsNone(session.start_turn(5))
        self.assertEqual(session.turn.n, 1)

    def test_stop_after_the_registry_went_idle_still_reads_the_turn(self):
        session = Session(id="s")
        session.start_turn(0)
        session.observe("busy", None, 1, registry=True)
        session.observe("idle", None, 10, registry=True)
        self.assertEqual(session.end_turn(12), 1)

    def test_registry_still_busy_after_stop_starts_nothing(self):
        session = Session(id="s")
        session.observe("busy", None, 0, registry=True)
        session.start_turn(1)
        session.end_turn(10)
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


class DismissTest(unittest.TestCase):
    def test_dismissed_turn_is_idle_until_the_next_one_ends(self):
        session = finished()
        self.assertTrue(session.dismiss())
        self.assertEqual(session.state(200), "idle")
        n = session.start_turn(300)
        session.end_turn(310)
        session.read(n, DONE, 320)
        self.assertEqual(session.state(330), "done")

    def test_nothing_to_dismiss_while_unread(self):
        session = Session(id="s")
        session.start_turn(0)
        self.assertFalse(session.dismiss())


class RowTest(unittest.TestCase):
    def test_persons_name_beats_the_label_which_beats_the_derived_name(self):
        session = Session(id="s", cwd="/home/x/repo", derived="repo-12")
        self.assertEqual(session.row(0)["name"], "repo-12")
        session.label = "retry flakes"
        self.assertEqual(session.row(0)["name"], "retry flakes")
        session.name = "mine"
        self.assertEqual(session.row(0)["name"], "mine")

    def test_saved_session_loads_as_it_was(self):
        session = finished(BLOCKED)
        session.label = "fixture cleanup"
        again = Session.load(session.saved(), 999)
        self.assertEqual(again.row(1000), session.row(1000))

    def test_a_turn_a_restart_caught_comes_back_to_be_read(self):
        session = Session(id="s")
        n = session.start_turn(0)
        again = Session.load(session.saved(), 999)
        self.assertTrue(again.turn.restored and again.turn.open)
        session.end_turn(10)
        session.reading(n, True)
        again = Session.load(session.saved(), 999)
        self.assertTrue(again.turn.restored)
        self.assertEqual(again.state(1000), "idle")
        self.assertEqual(again.end_turn(1000), n)

    def test_a_turn_with_its_ending_read_comes_back_settled(self):
        self.assertFalse(Session.load(finished().saved(), 999).turn.restored)

    def test_order_puts_the_longest_waiting_attention_first_then_the_latest(self):
        rows = [{"state": s, "since": t} for s, t in
                [("idle", 5), ("done", 9), ("asking", 8), ("working", 7), ("asking", 3), ("idle", 6), ("failed", 1)]]
        self.assertEqual([(r["state"], r["since"]) for r in ordered(rows)],
                         [("asking", 3), ("asking", 8), ("failed", 1), ("done", 9), ("working", 7), ("idle", 6), ("idle", 5)])


def row(state="needs-reply", since=100, window=None, rid="s"):
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

    def test_an_ask_pulses_until_you_look_or_open_the_popout(self):
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
