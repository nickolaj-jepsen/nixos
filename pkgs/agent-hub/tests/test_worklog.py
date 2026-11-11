"""Finding sessions in the work log, old lines included."""

import unittest

from agent_hub.worklog import by_session, matches, name_of


class FindTest(unittest.TestCase):
    def test_a_line_is_found_by_its_name_or_what_it_did(self):
        group = [{"session": "a", "at": 1, "name": "retry flakes", "did": "Fixed the backoff."}]
        self.assertTrue(matches(group, ["retry", "BACKOFF"]))
        self.assertFalse(matches(group, ["retry", "fixture"]))

    def test_a_line_from_before_the_gate_went_names_it_by_its_label(self):
        line = {"session": "a", "at": 1, "label": "retry flakes", "did": ""}
        self.assertEqual(name_of(line), "retry flakes")
        self.assertTrue(matches([line], ["flakes"]))

    def test_lines_group_by_session_latest_group_last(self):
        lines = [{"session": "a", "at": 1}, {"session": "b", "at": 2}, {"session": "a", "at": 3}]
        self.assertEqual([[line["at"] for line in group] for group in by_session(lines)], [[2], [1, 3]])
