"""Ageing out scratch, including the trees a plain recursive delete gives up on."""

import os
import tempfile
import time
import unittest
from pathlib import Path

from agent_notes import reap

OLD = 4 * reap.DAY


class ReapTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.root = Path(self.home.name) / "tmp"
        self.repo = self.root / "shop-0123abcd"
        self.repo.mkdir(parents=True)

    def aged(self, path, age=OLD):
        """Backdate an entry, the way an idle session leaves it."""
        stamp = time.time() - age
        os.utime(path, (stamp, stamp), follow_symlinks=False)
        return path

    def session(self, name="1234"):
        path = self.repo / name
        path.mkdir()
        (path / "notes.md").write_text("scratch\n")
        return path

    def test_a_read_only_tree_goes(self):
        # Go's module cache: the directories are not writable, so files inside cannot be unlinked.
        session = self.session()
        module = session / "go" / "mod" / "yaml@v1.4.0"
        module.mkdir(parents=True)
        (module / "go.mod").write_text("module yaml\n")
        for directory, _dirs, files in os.walk(session):
            for name in files:
                os.chmod(Path(directory) / name, 0o444)
            os.chmod(directory, 0o555)
        self.aged(session)

        summary = reap.reap(self.root, apply=True, say=lambda _message: None)

        self.assertFalse(session.exists())
        self.assertEqual(summary["removed"], 1)
        self.assertEqual(summary["blocked"], [])

    def test_an_unreadable_empty_directory_goes(self):
        session = self.session()
        (session / "work").mkdir()
        os.chmod(session / "work", 0o000)
        self.aged(session)

        reap.reap(self.root, apply=True, say=lambda _message: None)

        self.assertFalse(session.exists())

    def test_a_recent_entry_stays(self):
        session = self.session()
        self.aged(session, reap.DAY / 2)

        summary = reap.reap(self.root, apply=True, say=lambda _message: None)

        self.assertTrue((session / "notes.md").is_file())
        self.assertEqual(summary["stale"], 0)

    def test_the_repository_directory_stays(self):
        # A checkout's `.agents/tmp` link points at this, so it outlives its sessions.
        self.aged(self.repo)
        session = self.session()
        self.aged(session)

        reap.reap(self.root, apply=True, say=lambda _message: None)

        self.assertTrue(self.repo.is_dir())
        self.assertFalse(session.exists())

    def test_a_scratch_file_beside_a_session_goes(self):
        scratch = self.repo / "tmp.4V6n6VBkSI"
        scratch.write_text("kept too long\n")
        self.aged(scratch)

        reap.reap(self.root, apply=True, say=lambda _message: None)

        self.assertFalse(scratch.exists())

    def test_a_dry_run_deletes_nothing(self):
        session = self.session()
        self.aged(session)

        summary = reap.reap(self.root, apply=False, say=lambda _message: None)

        self.assertTrue((session / "notes.md").is_file())
        self.assertEqual(summary["stale"], 1)
        self.assertEqual(summary["removed"], 0)


class ParseAgeTest(unittest.TestCase):
    def test_units(self):
        self.assertEqual(reap.parse_age("3d"), 3 * reap.DAY)
        self.assertEqual(reap.parse_age("12h"), 12 * 60 * 60)
        self.assertEqual(reap.parse_age("90m"), 90 * 60)
        self.assertEqual(reap.parse_age("45s"), 45)

    def test_a_bare_number_is_days(self):
        self.assertEqual(reap.parse_age("2"), 2 * reap.DAY)

    def test_nonsense_is_refused(self):
        for value in ["soon", "0", "-1d", ""]:
            with self.assertRaises(ValueError):
                reap.parse_age(value)


if __name__ == "__main__":
    unittest.main()
