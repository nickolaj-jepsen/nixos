"""The store's identity and its two links, driven against throwaway repositories."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from agent_notes import layout, links


def git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


class LayoutTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.env = {
            "AGENT_NOTES_DATA": str(Path(self.home.name) / "data" / "agents"),
            "AGENT_NOTES_STATE": str(Path(self.home.name) / "state" / "agents"),
            # A private home and XDG tree: the machine's own `git/ignore` hides `.agents`,
            # which would make these fixtures unable to commit one.
            "HOME": str(Path(self.home.name) / "home"),
            "XDG_CONFIG_HOME": str(Path(self.home.name) / "home" / ".config"),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
        }
        Path(self.env["HOME"]).mkdir(parents=True)
        for key, value in self.env.items():
            os.environ[key] = value
            self.addCleanup(os.environ.pop, key, None)
        self.repo = Path(self.home.name) / "code" / "shop"
        self.repo.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=self.repo)
        git("config", "user.email", "test@example.com", cwd=self.repo)
        git("config", "user.name", "Test", cwd=self.repo)
        (self.repo / "README").write_text("hi\n")
        git("add", "README", cwd=self.repo)
        git("commit", "-qm", "first", cwd=self.repo)

    def test_a_checkout_gets_a_hashed_id(self):
        self.assertRegex(layout.repo_id(self.repo), r"^shop-[0-9a-f]{8}$")

    def test_every_worktree_shares_the_id(self):
        worktree = Path(self.home.name) / "work" / "shop-branch"
        git("worktree", "add", "-q", "-b", "side", str(worktree), cwd=self.repo)
        self.assertEqual(layout.repo_id(worktree), layout.repo_id(self.repo))

    def test_two_checkouts_with_one_basename_differ(self):
        other = Path(self.home.name) / "elsewhere" / "shop"
        other.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=other)
        self.assertNotEqual(layout.repo_id(other), layout.repo_id(self.repo))

    def test_outside_git_every_directory_shares_global(self):
        plain = Path(self.home.name) / "scratch"
        plain.mkdir()
        self.assertEqual(layout.repo_id(plain), layout.GLOBAL)

    def test_init_links_the_store_and_scratch(self):
        self.assertEqual(links.ensure(self.repo), [])
        self.assertEqual(os.readlink(self.repo / ".agents/store"), str(layout.store_root() / layout.repo_id(self.repo)))
        self.assertEqual(os.readlink(self.repo / ".agents/tmp"), str(layout.tmp_root() / layout.repo_id(self.repo)))
        self.assertFalse((layout.store_root() / layout.repo_id(self.repo)).exists(), "the store is created by a write")

    def test_init_is_idempotent(self):
        links.ensure(self.repo)
        before = os.readlink(self.repo / ".agents/store")
        self.assertEqual(links.ensure(self.repo), [])
        self.assertEqual(os.readlink(self.repo / ".agents/store"), before)

    def test_init_leaves_a_real_directory_alone(self):
        (self.repo / ".agents" / "store").mkdir(parents=True)
        problems = links.ensure(self.repo)
        self.assertEqual(len(problems), 1)
        self.assertIn(".agents/store", problems[0])
        self.assertTrue((self.repo / ".agents" / "store").is_dir())

    def test_init_leaves_a_foreign_link_alone(self):
        (self.repo / ".agents").mkdir()
        (self.repo / ".agents" / "store").symlink_to("/somewhere/else")
        problems = links.ensure(self.repo)
        self.assertEqual(len(problems), 1)
        self.assertEqual(os.readlink(self.repo / ".agents" / "store"), "/somewhere/else")

    def test_init_refuses_a_tracked_link_path(self):
        (self.repo / ".agents" / "skills").mkdir(parents=True)
        (self.repo / ".agents" / "skills" / "SKILL.md").write_text("committed\n")
        (self.repo / ".agents" / "store").write_text("not a link\n")
        git("add", ".agents", cwd=self.repo)
        git("commit", "-qm", "skills", cwd=self.repo)
        problems = links.ensure(self.repo)
        self.assertEqual(len(problems), 1)
        self.assertIn("tracked", problems[0])

    def test_committed_skills_survive_the_links(self):
        (self.repo / ".agents" / "skills").mkdir(parents=True)
        (self.repo / ".agents" / "skills" / "SKILL.md").write_text("committed\n")
        git("add", ".agents", cwd=self.repo)
        git("commit", "-qm", "skills", cwd=self.repo)
        links.ensure(self.repo)
        self.assertTrue((self.repo / ".agents" / "skills" / "SKILL.md").is_file())

    def test_scratch_follows_the_repository_and_the_pid(self):
        first = layout.tmp_root() / layout.repo_id(self.repo) / "10"
        second = layout.tmp_root() / layout.repo_id(self.repo) / "11"
        self.assertNotEqual(first, second)
        self.assertEqual(first.parent, second.parent)


class CliTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.data = Path(self.home.name) / "data"
        self.state = Path(self.home.name) / "state"
        home = Path(self.home.name) / "home"
        home.mkdir()
        for key, value in {"AGENT_NOTES_DATA": str(self.data / "agents"), "AGENT_NOTES_STATE": str(self.state / "agents"),
                           "HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config")}.items():
            os.environ[key] = value
            self.addCleanup(os.environ.pop, key, None)
        self.repo = Path(self.home.name) / "code" / "shop"
        self.repo.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=self.repo)

    def run_cli(self, *args, cwd=None):
        out = subprocess.run(["python3", "-m", "agent_notes.cli", *args], cwd=cwd or self.repo,
                             capture_output=True, text=True,
                             env={**os.environ, "PYTHONPATH": str(Path(__file__).parent.parent)})
        return out

    def test_root_ensure_creates_the_store_only_on_ask(self):
        plain = self.run_cli("root")
        self.assertEqual(plain.returncode, 0)
        self.assertFalse(Path(plain.stdout.strip()).exists())
        ensured = self.run_cli("root", "--ensure")
        self.assertTrue(Path(ensured.stdout.strip()).is_dir())
        self.assertTrue((self.repo / ".agents" / "store").is_symlink())

    def test_tmp_creates_a_pid_directory(self):
        out = self.run_cli("tmp", "4242")
        directory = Path(out.stdout.strip())
        self.assertEqual(directory.name, "4242")
        self.assertTrue(directory.is_dir())
        self.assertEqual(directory.parent, self.state / "agents" / "tmp" / layout.repo_id(self.repo))

    def test_init_outside_git_does_nothing(self):
        plain = Path(self.home.name) / "scratch"
        plain.mkdir()
        out = self.run_cli("init", cwd=plain)
        self.assertEqual(out.returncode, 0)
        self.assertFalse((plain / ".agents").exists())


if __name__ == "__main__":
    unittest.main()
