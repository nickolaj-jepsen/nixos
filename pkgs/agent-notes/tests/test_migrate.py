"""The migration, rehearsed on a fixture of the old per-project layout."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from agent_notes import layout, migrate


def write(path, text="x\n"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class MigrateTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        home = Path(self.home.name)
        self.data = home / ".local" / "share" / "agents"
        os.environ["HOME"] = str(home)
        os.environ["AGENT_NOTES_DATA"] = str(self.data)
        os.environ["AGENT_NOTES_STATE"] = str(home / ".local" / "state" / "agents")
        for key in ("HOME", "AGENT_NOTES_DATA", "AGENT_NOTES_STATE"):
            self.addCleanup(os.environ.pop, key, None)
        # A checkout the mapping can recognise by name.
        self.repo = home / "dev" / "shop"
        self.repo.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=self.repo, check=True,
                       env={**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull})
        self.id = layout.repo_id(self.repo)
        self.repos = {"shop": self.id}

        old = self.data / "shop"
        write(old / "plans" / "app" / "PLAN.md", "See ~/.local/share/agents/shop/plans/app/spikes/run.log for the log.\n")
        write(old / "plans" / "app" / "spikes" / "run.log", "log\n")
        write(old / "plans" / "app" / "history" / "PLAN.prev.md", "old plan\n")
        write(old / "plans" / "app" / "stray.bin", "nobody names me\n")
        write(old / "findings" / "hub.md", "findings\n")
        write(old / "scripts" / "one-off.py", "print()\n")
        write(self.data / "gone-project" / "PLAN.md", "orphan\n")
        write(self.data / "gone-project" / "blob.bin", "orphan blob\n")

    def test_plan_maps_known_projects_and_orphans_the_rest(self):
        result = migrate.plan(repos=self.repos)
        moves = {str(source): str(destination) for source, destination in result["moves"]}
        self.assertIn(str(self.data / "shop/findings/hub.md"), moves)
        self.assertTrue(moves[str(self.data / "shop/findings/hub.md")].endswith(f"store/{self.id}/findings/hub.md"))
        self.assertTrue(moves[str(self.data / "shop/plans/app/spikes/run.log")]
                        .endswith(f"store/{self.id}/plans/app/files/spikes/run.log"))
        self.assertIn(str(self.data / "shop/plans/app/history/PLAN.prev.md"), moves)

    def test_plan_separates_named_artifacts_from_unclaimed_files(self):
        result = migrate.plan(repos=self.repos)
        unclaimed = {str(path) for _, path, _relative in result["unclaimed"]}
        self.assertIn(str(self.data / "shop/plans/app/stray.bin"), unclaimed)
        self.assertNotIn(str(self.data / "shop/plans/app/spikes/run.log"), unclaimed)

    def test_unresolved_markdown_is_orphaned_and_its_blobs_are_not(self):
        result = migrate.plan(repos=self.repos)
        orphans = {str(source) for source, _ in result["orphans"]}
        self.assertIn(str(self.data / "gone-project/PLAN.md"), orphans)
        unclaimed = {str(path) for _, path, _relative in result["unclaimed"]}
        self.assertIn(str(self.data / "gone-project/blob.bin"), unclaimed)

    def test_apply_moves_rewrites_and_deletes(self):
        result = migrate.plan(repos=self.repos)
        summary = migrate.apply(result, say=lambda _message: None)
        store = layout.store_root() / self.id
        self.assertTrue((store / "findings" / "hub.md").is_file())
        self.assertTrue((store / "plans" / "app" / "files" / "spikes" / "run.log").is_file())
        self.assertTrue((store / "plans" / "app" / "history" / "PLAN.prev.md").is_file())
        self.assertFalse((store / "plans" / "app" / "stray.bin").exists())
        self.assertFalse((self.data / "shop").exists())
        plan = (store / "plans" / "app" / "PLAN.md").read_text()
        self.assertIn(f"~/.local/share/agents/store/{self.id}/plans/app/files/spikes/run.log", plan)
        self.assertNotIn("agents/shop/plans", plan)
        self.assertTrue((layout.orphan_root() / "gone-project" / "PLAN.md").is_file())
        self.assertFalse((layout.orphan_root() / "gone-project" / "blob.bin").exists())
        self.assertEqual(summary["deleted"], 3)
        self.assertEqual(summary["orphans"], 1)

    def test_keep_unclaimed_puts_blobs_beside_the_orphan(self):
        result = migrate.plan(repos=self.repos)
        migrate.apply(result, keep_unclaimed=True, say=lambda _message: None)
        self.assertTrue((layout.orphan_root() / "gone-project" / "unclaimed" / "blob.bin").is_file())
        self.assertTrue((layout.store_root() / self.id / "plans" / "app" / "files" / "stray.bin").exists()
                        or (layout.orphan_root() / "shop").exists())

    def test_a_symlinked_directory_moves_as_the_link_it_is(self):
        outside = Path(self.home.name) / "elsewhere"
        write(outside / "payload.txt", "not mine to copy\n")
        (self.data / "shop" / "plans" / "app" / "link").symlink_to(outside)
        plan = self.data / "shop/plans/app/PLAN.md"
        plan.write_text(plan.read_text() + "Sources: ~/.local/share/agents/shop/plans/app/link\n")
        result = migrate.plan(repos=self.repos)
        moves = {str(source): str(destination) for source, destination in result["moves"]}
        linked = str(self.data / "shop/plans/app/link")
        self.assertIn(linked, moves)
        migrate.apply(result, say=lambda _message: None)
        moved = layout.store_root() / self.id / "plans" / "app" / "files" / "link"
        self.assertTrue(moved.is_symlink())
        self.assertEqual(os.readlink(moved), str(outside), "the link keeps pointing where it did")

    def test_two_projects_landing_on_one_path_are_refused_not_merged(self):
        write(self.data / "shop" / "hub.md", "one\n")
        write(self.data / "second" / "hub.md", "two\n")
        repos = {**self.repos, "second": self.id}
        result = migrate.plan(repos=repos)
        with self.assertRaises(SystemExit) as refused:
            migrate.apply(result, say=lambda _message: None)
        self.assertIn("two sources want", str(refused.exception))
        self.assertTrue((self.data / "shop" / "hub.md").is_file(), "nothing moves when two sources collide")

    def test_a_project_whose_checkout_is_found_later_leaves_the_orphan_folder(self):
        orphan = layout.orphan_root() / "shop"
        write(orphan / "PLAN.md", "orphaned plan\n")
        write(orphan / "history" / "old.md", "history\n")
        write(orphan / "unclaimed" / "blob.bin", "parked\n")
        # The checkout is known now, so the Markdown moves home and the parked file stays.
        result = migrate.plan(repos=self.repos)
        moves = {str(source): str(destination) for source, destination in result["moves"]}
        self.assertIn(str(orphan / "PLAN.md"), moves)
        self.assertTrue(moves[str(orphan / "PLAN.md")].endswith(f"store/{self.id}/PLAN.md"))
        self.assertNotIn(str(orphan / "unclaimed" / "blob.bin"), moves)
        migrate.apply(result, keep_unclaimed=True, say=lambda _message: None)
        self.assertTrue((layout.store_root() / self.id / "PLAN.md").is_file())
        self.assertTrue((orphan / "unclaimed" / "blob.bin").is_file())

    def test_a_worktree_names_its_main_checkout_for_discovery(self):
        main = Path(self.home.name) / "work" / "mono" / "projects" / "nested-repo"
        main.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=main, check=True,
                       env={**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull})
        worktree = Path(self.home.name) / "worktrees" / "nested-repo" / "topic"
        subprocess.run(["git", "worktree", "add", "-q", "-b", "topic", str(worktree)], cwd=main, check=True,
                       env={**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull})
        found = migrate.discover()
        self.assertEqual(found.get("nested-repo"), layout.repo_id(main))

    def test_apply_refuses_to_overwrite_a_store_that_already_holds_the_path(self):
        write(layout.store_root() / self.id / "findings" / "hub.md", "already here\n")
        result = migrate.plan(repos=self.repos)
        with self.assertRaises(SystemExit):
            migrate.apply(result, say=lambda _message: None)


if __name__ == "__main__":
    unittest.main()
