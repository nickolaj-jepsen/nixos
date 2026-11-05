#!/usr/bin/env python3
"""CLI-level tests for wt against real temporary git repositories.

Run with `PYTHONPATH=pkgs/wt python3 pkgs/wt/tests/test_cli.py`, or through
`nix build .#wt`, which runs the installed binary through WT_BIN.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

WT_BIN = os.environ.get("WT_BIN")
PKG_ROOT = Path(__file__).resolve().parents[1]
WT_CMD = [WT_BIN] if WT_BIN else [sys.executable, "-m", "wt"]


class Base(unittest.TestCase):
    """A repository with one commit on main, and a worktree root of its own."""

    def setUp(self) -> None:
        self.root = tempfile.mkdtemp(prefix="wt-tests-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.main = os.path.join(self.root, "repo")
        os.makedirs(self.main)
        self.env = os.environ.copy()
        self.env.update(
            {
                "HOME": self.root,
                "WT_WORKTREE_ROOT": os.path.join(self.root, "trees"),
                "WT_WHEN_FREE_TIMEOUT": "20",
                "GIT_CONFIG_GLOBAL": os.path.join(self.root, "gitconfig"),
                "GIT_CONFIG_SYSTEM": os.devnull,
                "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z",
                "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
            }
        )
        Path(self.env["GIT_CONFIG_GLOBAL"]).write_text("")
        if not WT_BIN:
            # The subprocess runs in a fixture repo, so a relative PYTHONPATH breaks.
            self.env["PYTHONPATH"] = str(PKG_ROOT)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.write("a.txt", "base\n")
        self.commit("base")

    # helpers -----------------------------------------------------------------

    def wt(self, *args: str, cwd: str | None = None, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(
            [*WT_CMD, *args], cwd=cwd or self.main, env=self.env, text=True, capture_output=True, check=check
        )

    def git(self, *args: str, cwd: str | None = None, check: bool = True) -> str:
        return subprocess.run(
            ["git", *args], cwd=cwd or self.main, env=self.env, text=True, capture_output=True, check=check
        ).stdout

    def write(self, name: str, text: str, cwd: str | None = None) -> None:
        Path(cwd or self.main, name).write_text(text)

    def commit(self, message: str, cwd: str | None = None) -> None:
        self.git("add", "-A", cwd=cwd)
        self.git("commit", "-qm", message, cwd=cwd)

    def new(self, name: str, *base: str) -> Path:
        return Path(self.wt("new", name, *base).stdout.strip())

    def feature(self, name: str, filename: str = "b.txt") -> Path:
        path = self.new(name)
        self.write(filename, f"{name}\n", cwd=str(path))
        self.commit(name, cwd=str(path))
        return path

    def entry(self, name: str) -> dict:
        document = json.loads(self.wt("list", "--json").stdout)
        for row in document["repos"][0]["worktrees"]:
            if row["name"] == name:
                return row
        self.fail(f"no worktree {name} in {document}")

    def has_branch(self, branch: str) -> bool:
        return bool(self.git("branch", "--list", branch).strip())

    def current(self, cwd: str | None = None) -> str:
        return self.git("branch", "--show-current", cwd=cwd).strip()

    def subject(self, ref: str = "HEAD", cwd: str | None = None) -> str:
        return self.git("log", "-1", "--format=%s", ref, cwd=cwd).strip()

    def sleeper(self, cwd: Path) -> subprocess.Popen:
        process = subprocess.Popen(["sleep", "60"], cwd=str(cwd))
        self.addCleanup(lambda: (process.kill(), process.wait()))
        time.sleep(0.2)
        return process

    def wait_gone(self, path: Path, seconds: float = 15) -> None:
        deadline = time.time() + seconds
        while path.exists() and time.time() < deadline:
            time.sleep(0.2)
        self.assertFalse(path.exists(), f"{path} still exists")

    def git_dir(self, path: Path) -> Path:
        return Path(self.git("rev-parse", "--absolute-git-dir", cwd=str(path)).strip())

    def corrupt_index(self, path: Path) -> None:
        """Break a worktree's index, as a damaged checkout does: every probe that reads it fails."""
        index = self.git_dir(path) / "index"
        self.assertTrue(index.is_file(), f"no index at {index}")
        index.chmod(0o644)
        index.write_bytes(b"garbage")

    def corrupt_loose_object(self, sha: str) -> None:
        """Break one loose object, as a damaged repository does: commits walked through it fail."""
        loose = Path(self.git("rev-parse", "--absolute-git-dir").strip(), "objects", sha[:2], sha[2:])
        self.assertTrue(loose.is_file(), f"{sha} is not a loose object")
        loose.chmod(0o644)
        loose.write_bytes(b"garbage")

    def other_repo(self, name: str) -> str:
        """A second repository beside the first, with its own commit on main."""
        path = os.path.join(self.root, name)
        os.makedirs(path)
        self.git("init", "-q", "-b", "main", cwd=path)
        self.git("config", "user.email", "test@example.com", cwd=path)
        self.git("config", "user.name", "Test", cwd=path)
        self.write("a.txt", f"{name}\n", cwd=path)
        self.commit(name, cwd=path)
        return path


class Local(Base):
    # interface ---------------------------------------------------------------

    def test_help_lists_exactly_the_verbs(self) -> None:
        usage = self.wt("--help").stdout
        block = usage.split("  <verb>\n", 1)[1].split("\n\n", 1)[0]
        listed = [line.split()[0] for line in block.splitlines()]
        self.assertEqual(sorted(listed), sorted(["new", "land", "close", "drop", "list", "cd"]))

    # new, list, cd -----------------------------------------------------------

    def test_new_is_outside_the_checkout_and_round_trips(self) -> None:
        path = self.new("feature")
        self.assertTrue(str(path).startswith(self.env["WT_WORKTREE_ROOT"]))
        self.assertEqual(self.wt("cd", "feature").stdout.strip(), str(path))
        self.assertEqual(self.wt("list", "--name").stdout.split(), ["feature"])
        self.assertEqual(self.wt("new", "feature").stdout.strip(), str(path))

    def test_new_names_the_folder_of_a_slashed_branch_with_dashes(self) -> None:
        path = self.new("feat/x")
        self.assertEqual(path.name, "feat-x")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(path)).strip(), "feat/x")
        self.assertEqual(self.wt("cd", "feat/x").stdout.strip(), str(path))

    def test_new_refuses_a_folder_that_holds_another_branch(self) -> None:
        path = self.feature("feat/y")
        self.assertEqual(path.name, "feat-y")
        self.assertEqual(self.wt("new", "feat/y").stdout.strip(), str(path))
        result = self.wt("new", "feat-y", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("feat/y", result.stderr)
        self.assertIn("feat-y", result.stderr)
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(path)).strip(), "feat/y")
        self.wt("close", "feat/y")
        self.assertFalse(path.exists())
        result = self.wt("new", "feat-y", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("feat/y", result.stderr)
        self.assertFalse(path.exists())
        self.assertEqual(self.new("feat/y"), path)
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(path)).strip(), "feat/y")

    def test_list_json_shows_open_and_closed(self) -> None:
        self.feature("kept")
        self.new("open")
        self.wt("close", "kept")
        rows = {row["name"]: row for row in json.loads(self.wt("list", "--json").stdout)["repos"][0]["worktrees"]}
        self.assertTrue(rows["open"]["open"])
        self.assertFalse(rows["kept"]["open"])
        self.assertIsNone(rows["kept"]["path"])
        self.assertEqual(rows["kept"]["ahead"], 1)
        self.assertEqual(sorted(self.wt("list", "--name").stdout.split()), ["kept", "open"])

    def test_same_basename_repositories_get_separate_roots(self) -> None:
        other = os.path.join(self.root, "elsewhere", "repo")
        os.makedirs(other)
        self.git("init", "-q", "-b", "main", cwd=other)
        self.git("config", "user.email", "test@example.com", cwd=other)
        self.git("config", "user.name", "Test", cwd=other)
        self.write("a.txt", "other\n", cwd=other)
        self.commit("other", cwd=other)
        first = self.new("feature")
        second = Path(self.wt("new", "feature", cwd=other).stdout.strip())
        self.assertNotEqual(first, second)
        document = json.loads(self.wt("list", "--all", "--json", cwd=self.root).stdout)
        self.assertEqual([len(repo["worktrees"]) for repo in document["repos"]], [1, 1])

    def test_list_leaves_the_metadata_it_reports_untouched(self) -> None:
        path = self.feature("mtime")
        # An edit leaves the index's cached stat stale, so the next `git status` rewrites it: the
        # listing has to read that state, not cause it.
        self.write("b.txt", "edited\n", cwd=str(path))
        old = time.time() - 3 * 3600
        stamps = [self.git_dir(path) / name for name in ("index", "HEAD")]
        for stamp in stamps:
            os.utime(stamp, (old, old))
        row = self.entry("mtime")
        for stamp in stamps:
            self.assertEqual(int(stamp.stat().st_mtime), int(old), f"listing rewrote {stamp}")
        self.assertTrue(row["dirty"])
        # The index and HEAD stamps are what the row reports on, so a reset index would read 0s.
        self.assertGreaterEqual(row["idleSeconds"], 3 * 3600 - 60)
        self.assertLess(row["idleSeconds"], 3 * 3600 + 300)

    def test_list_reads_a_detached_worktrees_own_commits(self) -> None:
        path = self.new("detached")
        self.git("switch", "-q", "--detach", cwd=str(path))
        self.write("b.txt", "detached work\n", cwd=str(path))
        self.commit("detached work", cwd=str(path))
        # The primary checkout moves on: its tip is no answer for this worktree.
        self.write("a.txt", "moved on\n")
        self.commit("moved on")
        old = time.time() - 3 * 3600
        for name in ("index", "HEAD"):
            os.utime(self.git_dir(path) / name, (old, old))
        row = self.entry("detached")
        self.assertTrue(row["open"])
        self.assertEqual(row["branch"], "")
        self.assertEqual(row["ahead"], 1)
        self.assertGreaterEqual(row["idleSeconds"], 3 * 3600)
        self.assertLess(row["idleSeconds"], 4 * 3600)

    def test_a_deleted_folder_lists_as_closed_and_new_recreates_it(self) -> None:
        path = self.feature("gone")
        shutil.rmtree(path)
        listed = self.wt("list", "--json", check=False)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        row = {row["name"]: row for row in json.loads(listed.stdout)["repos"][0]["worktrees"]}["gone"]
        self.assertFalse(row["open"])
        self.assertIsNone(row["path"])
        self.assertEqual(self.wt("list", "--name").stdout.split(), ["gone"])
        reopened = self.new("gone")
        self.assertEqual(reopened, path)
        self.assertEqual(Path(reopened, "b.txt").read_text(), "gone\n")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(reopened)).strip(), "gone")
        self.assertTrue(self.entry("gone")["open"])
        self.assertNotIn("prunable", self.git("worktree", "list", "--porcelain"))

    def test_a_detached_registration_whose_folder_is_gone_keeps_its_own_commit(self) -> None:
        """Detached and stale at once: the row must read the commit git recorded, not the primary HEAD."""
        path = self.new("detached")
        self.git("switch", "-q", "--detach", cwd=str(path))
        self.write("b.txt", "detached work\n", cwd=str(path))
        self.commit("detached work", cwd=str(path))
        sha = self.git("rev-parse", "HEAD", cwd=str(path)).strip()
        shutil.rmtree(path)
        listed = self.wt("list", "--json", check=False)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        row = {row["name"]: row for row in json.loads(listed.stdout)["repos"][0]["worktrees"]}["detached"]
        self.assertFalse(row["open"])
        self.assertIsNone(row["path"])
        self.assertEqual(row["branch"], "")
        self.assertEqual(row["ahead"], 1)
        self.assertFalse(row["landed"])
        self.assertIsNone(row["error"])
        dropped = self.wt("drop", "detached")
        self.assertIn(f"git branch recovered/detached {sha}", dropped.stderr)
        self.assertNotIn("prunable", self.git("worktree", "list", "--porcelain"))

    def test_new_refuses_a_registration_with_no_branch_and_keeps_it(self) -> None:
        path = self.new("gone")
        self.git("switch", "-q", "--detach", cwd=str(path))
        sha = self.git("rev-parse", "HEAD", cwd=str(path)).strip()
        shutil.rmtree(path)
        refused = self.wt("new", "gone", check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn(sha, refused.stderr)
        self.assertFalse(path.exists())
        # The registration is what still names the commit: pruning it here would lose it.
        self.assertIn("prunable", self.git("worktree", "list", "--porcelain"))

    def test_list_all_reports_a_root_whose_repository_is_gone(self) -> None:
        self.feature("healthy")
        other = self.other_repo("vanished")
        self.wt("new", "parked", cwd=other)
        shutil.rmtree(Path(other, ".git"))
        result = self.wt("list", "--all", "--json", cwd=self.root, check=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        document = json.loads(result.stdout)
        repos = {repo["name"]: repo for repo in document["repos"]}
        self.assertEqual([row["name"] for row in repos["repo"]["worktrees"]], ["healthy"])
        self.assertIsNone(repos["vanished"]["main"])
        self.assertEqual(repos["vanished"]["worktrees"], [])
        self.assertIn("vanished", repos["vanished"]["error"])
        self.assertIn("vanished", result.stderr)

    def test_list_creates_nothing_in_the_worktree_root(self) -> None:
        root = Path(self.root, "trees")
        self.assertEqual(self.wt("list").returncode, 0)
        self.assertFalse(root.exists(), "listing created the worktree root")
        self.assertEqual(self.wt("list", "--all").returncode, 0)
        self.assertFalse(root.exists(), "listing created a root entry to discover")

    # list: inspection errors -------------------------------------------------
    def test_list_all_json_keeps_a_healthy_repository_beside_a_broken_one(self) -> None:
        self.feature("healthy")
        other = self.other_repo("broken")
        hurt = Path(self.wt("new", "hurt", cwd=other).stdout.strip())
        self.corrupt_index(hurt)
        result = self.wt("list", "--all", "--json", cwd=self.root, check=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        document = json.loads(result.stdout)
        self.assertEqual(document["version"], 3)
        repos = {repo["name"]: repo for repo in document["repos"]}
        self.assertEqual(sorted(repos), ["broken", "repo"])
        healthy = repos["repo"]
        self.assertIsNone(healthy["error"])
        self.assertEqual(
            [(row["name"], row["dirty"], row["error"]) for row in healthy["worktrees"]],
            [("healthy", False, None)],
        )
        broken = repos["broken"]["worktrees"]
        self.assertEqual([row["name"] for row in broken], ["hurt"])
        self.assertTrue(broken[0]["open"])
        self.assertIsNone(broken[0]["dirty"])
        self.assertTrue(broken[0]["error"])
        self.assertIn("hurt", result.stderr)

    def test_list_marks_an_unknown_value_and_exits_1_for_one_broken_repository(self) -> None:
        path = self.feature("hurt")
        self.corrupt_index(path)
        table = self.wt("list", check=False)
        self.assertEqual(table.returncode, 1, table.stderr)
        cells = [line.split() for line in table.stdout.splitlines()]
        header, row = cells[0], cells[1]
        # The broken row's own DIRTY cell says the value is unknown, not that the tree is clean.
        self.assertEqual(row[header.index("DIRTY")], "?")
        self.assertEqual(row[header.index("NAME")], "hurt")
        answer = self.wt("list", "--json", check=False)
        self.assertEqual(answer.returncode, 1, answer.stderr)
        row = json.loads(answer.stdout)["repos"][0]["worktrees"][0]
        self.assertEqual(row["name"], "hurt")
        self.assertIsNone(row["dirty"])
        self.assertIsNotNone(row["error"])

    def test_list_json_reports_no_errors_when_everything_was_inspected(self) -> None:
        self.feature("kept")
        self.new("open")
        self.wt("close", "kept")
        result = self.wt("list", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(result.stdout)
        self.assertEqual(document["version"], 3)
        self.assertIsNone(document["repos"][0]["error"])
        rows = document["repos"][0]["worktrees"]
        self.assertEqual(sorted(row["name"] for row in rows), ["kept", "open"])
        for row in rows:
            self.assertIsNone(row["error"], row)
            for key in ("ahead", "landed", "dirty", "wip", "idleSeconds"):
                self.assertIsNotNone(row[key], f"{row['name']}.{key}")

    def test_list_all_names_a_repository_it_cannot_identify(self) -> None:
        self.feature("healthy")
        other = self.other_repo("unreadable")
        self.wt("new", "parked", cwd=other)
        # A half-written config is what a damaged .git looks like: git cannot name its worktrees.
        Path(other, ".git", "config").write_text("[core\n")
        result = self.wt("list", "--all", "--json", cwd=self.root, check=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        document = json.loads(result.stdout)
        self.assertEqual(document["version"], 3)
        repos = {repo["name"]: repo for repo in document["repos"]}
        self.assertEqual(sorted(repos), ["repo", "unreadable"])
        self.assertEqual([row["name"] for row in repos["repo"]["worktrees"]], ["healthy"])
        self.assertEqual(repos["unreadable"]["worktrees"], [])
        self.assertIsNone(repos["unreadable"]["main"])
        self.assertIn("config", repos["unreadable"]["error"])

    # close -------------------------------------------------------------------

    def test_close_commits_the_dirty_tree_and_new_brings_it_back(self) -> None:
        path = self.feature("work")
        self.write("b.txt", "edited\n", cwd=str(path))
        self.write("untracked.txt", "fresh\n", cwd=str(path))
        self.wt("close", "work")
        self.assertFalse(path.exists())
        self.assertIn("Wt-Wip: 1", self.git("log", "-1", "--format=%B", "work"))
        self.assertEqual(self.entry("work")["wip"], True)
        reopened = self.new("work")
        self.assertEqual(reopened, path)
        self.assertEqual(Path(path, "b.txt").read_text(), "edited\n")
        self.assertEqual(Path(path, "untracked.txt").read_text(), "fresh\n")
        self.assertEqual(self.subject(cwd=str(path)), "work")

    def test_close_commits_untracked_work_that_status_configuration_hides(self) -> None:
        self.git("config", "status.showUntrackedFiles", "no")
        path = self.new("hidden")
        self.write("fresh.txt", "fresh\n", cwd=str(path))
        self.wt("close", "hidden")
        self.assertFalse(path.exists())
        self.assertIn("fresh.txt", self.git("ls-tree", "-r", "--name-only", "hidden", check=False))
        self.assertEqual(self.git("show", "hidden:fresh.txt", check=False), "fresh\n")

    def test_close_aborts_when_the_index_cannot_be_read(self) -> None:
        path = self.feature("broken")
        self.write("b.txt", "edited\n", cwd=str(path))
        self.corrupt_index(path)
        result = self.wt("close", "broken", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken", result.stderr)
        self.assertTrue(path.exists())
        self.assertTrue(self.has_branch("broken"))
        self.assertEqual(Path(path, "b.txt").read_text(), "edited\n")

    def test_close_of_a_clean_worktree_succeeds(self) -> None:
        path = self.feature("clean")
        result = self.wt("close", "clean", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(path.exists())
        self.assertTrue(self.has_branch("clean"))

    def test_close_reopens_on_the_branch_it_was_closed_on(self) -> None:
        path = self.new("stacked")
        self.git("switch", "-qc", "layer-two", cwd=str(path))
        self.write("c.txt", "two\n", cwd=str(path))
        self.commit("two", cwd=str(path))
        self.wt("close", "stacked")
        self.new("stacked")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(path)).strip(), "layer-two")

    def test_close_ignores_commit_signing(self) -> None:
        path = self.new("signed")
        self.git("config", "commit.gpgsign", "true")
        self.git("config", "gpg.program", "false")
        self.write("b.txt", "work\n", cwd=str(path))
        self.wt("close", "signed")
        self.assertFalse(path.exists())
        self.assertTrue(self.entry("signed")["wip"])

    def test_close_deletes_a_branch_whose_work_landed(self) -> None:
        path = self.feature("done")
        self.git("merge", "-q", "--ff-only", "done")
        self.wt("close", "done")
        self.assertFalse(path.exists())
        self.assertFalse(self.has_branch("done"))
        self.assertEqual(self.wt("list", "--name").stdout.split(), [])

    def test_close_deletes_a_branch_with_no_commits(self) -> None:
        self.new("empty")
        self.wt("close", "empty")
        self.assertFalse(self.has_branch("empty"))

    def test_close_refuses_a_detached_commit_nothing_else_points_to(self) -> None:
        path = self.new("loose")
        self.git("switch", "-q", "--detach", cwd=str(path))
        self.write("b.txt", "detached work\n", cwd=str(path))
        self.commit("detached work", cwd=str(path))
        sha = self.git("rev-parse", "HEAD", cwd=str(path)).strip()
        closed = self.wt("close", "loose", check=False)
        self.assertNotEqual(closed.returncode, 0)
        self.assertIn("nothing else points to", closed.stderr)
        self.assertTrue(path.exists())
        self.assertEqual(self.git("cat-file", "-t", sha).strip(), "commit")
        dropped = self.wt("drop", "loose", check=False)
        self.assertNotEqual(dropped.returncode, 0)
        self.assertTrue(path.exists())

    def test_close_takes_a_detached_worktree_a_tag_still_names(self) -> None:
        path = self.new("tagged")
        self.git("switch", "-q", "--detach", cwd=str(path))
        self.write("b.txt", "tagged work\n", cwd=str(path))
        self.commit("tagged work", cwd=str(path))
        self.git("tag", "keep", "HEAD", cwd=str(path))
        self.git("branch", "-q", "-D", "tagged")
        self.wt("close", "tagged")
        self.assertFalse(path.exists())
        self.assertEqual(self.git("log", "-1", "--format=%s", "keep").strip(), "tagged work")

    def test_close_takes_a_detached_worktree_a_remote_ref_still_names(self) -> None:
        path = self.feature("moved")
        self.git("update-ref", "refs/remotes/origin/moved", "HEAD", cwd=str(path))
        self.git("switch", "-q", "--detach", "origin/moved", cwd=str(path))
        self.wt("close", "moved")
        self.assertFalse(path.exists())
        self.assertEqual(self.subject("origin/moved"), "moved")

    def test_new_leaves_another_stale_registration_alone(self) -> None:
        loose = self.new("loose")
        self.git("switch", "-q", "--detach", cwd=str(loose))
        self.write("b.txt", "detached work\n", cwd=str(loose))
        self.commit("precious", cwd=str(loose))
        sha = self.git("rev-parse", "HEAD", cwd=str(loose)).strip()
        shutil.rmtree(loose)
        kept = self.new("kept")
        shutil.rmtree(kept)
        self.new("kept")
        # The detached registration is the only thing naming its commit: prune only what blocks.
        self.assertEqual(self.git("cat-file", "-t", sha).strip(), "commit")
        self.assertIn("prunable", self.git("worktree", "list", "--porcelain"))

    def test_close_leaves_another_stale_registration_alone(self) -> None:
        loose = self.new("loose")
        self.git("switch", "-q", "--detach", cwd=str(loose))
        self.write("b.txt", "detached work\n", cwd=str(loose))
        self.commit("precious", cwd=str(loose))
        sha = self.git("rev-parse", "HEAD", cwd=str(loose)).strip()
        shutil.rmtree(loose)
        closed = self.feature("closing")
        self.wt("close", "closing")
        self.assertFalse(closed.exists())
        self.assertEqual(self.git("cat-file", "-t", sha).strip(), "commit")
        self.assertIn("prunable", self.git("worktree", "list", "--porcelain"))

    def test_drop_leaves_another_stale_registration_alone(self) -> None:
        loose = self.new("loose")
        self.git("switch", "-q", "--detach", cwd=str(loose))
        self.write("b.txt", "detached work\n", cwd=str(loose))
        self.commit("precious", cwd=str(loose))
        sha = self.git("rev-parse", "HEAD", cwd=str(loose)).strip()
        shutil.rmtree(loose)
        self.feature("dropped")
        self.wt("drop", "dropped")
        self.assertFalse(self.has_branch("dropped"))
        self.assertEqual(self.git("cat-file", "-t", sha).strip(), "commit")
        self.assertIn("prunable", self.git("worktree", "list", "--porcelain"))

    def test_close_settles_a_branch_a_deleted_folder_still_claims(self) -> None:
        gone = self.new("gone")
        shutil.rmtree(gone)
        self.feature("closing")
        closed = self.wt("close", "closing", check=False)
        self.assertEqual(closed.returncode, 0, closed.stderr)
        # The stale registration on a landed branch is repaired, and the close reports it.
        self.assertFalse(self.has_branch("gone"))
        self.assertIn("deleted gone", closed.stderr)

    def test_new_names_the_unlock_command_for_a_locked_registration(self) -> None:
        gone = self.new("gone")
        self.git("worktree", "lock", str(gone))
        shutil.rmtree(gone)
        refused = self.wt("new", "gone", check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("worktree unlock", refused.stderr)
        self.assertFalse(gone.exists())

    def test_close_keeps_a_branch_a_locked_registration_claims(self) -> None:
        gone = self.new("gone")
        self.git("worktree", "lock", str(gone))
        shutil.rmtree(gone)
        self.feature("closing")
        closed = self.wt("close", "closing", check=False)
        self.assertEqual(closed.returncode, 0, closed.stderr)
        self.assertTrue(self.has_branch("gone"))
        self.assertIn("worktree unlock", closed.stderr)

    def test_drop_keeps_a_branch_a_locked_registration_claims(self) -> None:
        gone = self.new("gone")
        self.git("worktree", "lock", str(gone))
        shutil.rmtree(gone)
        dropped = self.wt("drop", "gone", check=False)
        self.assertEqual(dropped.returncode, 0, dropped.stderr)
        self.assertTrue(self.has_branch("gone"))
        self.assertIn("worktree unlock", dropped.stderr)

    def test_close_keeps_unlanded_work(self) -> None:
        self.feature("unlanded")
        self.wt("close", "unlanded")
        self.assertTrue(self.has_branch("unlanded"))
        self.assertFalse(self.entry("unlanded")["open"])

    def test_close_refuses_mid_rebase(self) -> None:
        path = self.new("conflict")
        self.write("a.txt", "theirs\n", cwd=str(path))
        self.commit("theirs", cwd=str(path))
        self.write("a.txt", "ours\n")
        self.commit("ours")
        self.git("rebase", "main", cwd=str(path), check=False)
        result = self.wt("close", "conflict", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rebase", result.stderr)
        self.assertTrue(path.exists())

    def test_close_refuses_a_folder_in_use_and_when_free_waits_for_it(self) -> None:
        path = self.feature("busy")
        self.write("b.txt", "late edit\n", cwd=str(path))
        process = self.sleeper(path)
        result = self.wt("close", "busy", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"pid {process.pid}", result.stderr)
        self.wt("close", "--when-free", "busy")
        time.sleep(1.5)
        self.assertTrue(path.exists())
        process.kill()
        process.wait()
        self.wait_gone(path)
        self.assertTrue(self.entry("busy")["wip"])

    def test_close_refuses_the_folder_it_runs_in(self) -> None:
        path = self.new("self")
        result = self.wt("close", cwd=str(path), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--when-free", result.stderr)
        self.assertTrue(path.exists())

    def test_close_takes_a_path_from_outside_any_checkout(self) -> None:
        path = self.new("by-path")
        self.wt("close", str(path), cwd=self.root)
        self.assertFalse(path.exists())

    # drop --------------------------------------------------------------------

    def test_drop_deletes_unlanded_work_and_prints_its_way_back(self) -> None:
        path = self.feature("doomed")
        self.write("b.txt", "uncommitted\n", cwd=str(path))
        stderr = self.wt("drop", "doomed").stderr
        self.assertFalse(path.exists())
        self.assertFalse(self.has_branch("doomed"))
        restore = stderr.split("restore with: ", 1)[1].split()
        self.git(*restore[1:])
        self.assertEqual(self.git("show", "doomed:b.txt"), "uncommitted\n")

    def test_drop_keeps_untracked_work_that_status_configuration_hides(self) -> None:
        self.git("config", "status.showUntrackedFiles", "no")
        path = self.new("hidden")
        self.write("fresh.txt", "fresh\n", cwd=str(path))
        stderr = self.wt("drop", "hidden").stderr
        self.assertFalse(path.exists())
        restore = stderr.split("restore with: ", 1)[1].split()
        self.git(*restore[1:])
        self.assertEqual(self.git("show", "hidden:fresh.txt", check=False), "fresh\n")

    def test_drop_removes_the_branch_of_a_deleted_folder(self) -> None:
        path = self.feature("vanished")
        shutil.rmtree(path)
        result = self.wt("drop", "vanished", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        stderr = result.stderr
        self.assertFalse(self.has_branch("vanished"))
        restore = stderr.split("restore with: ", 1)[1].split()
        self.git(*restore[1:])
        self.assertEqual(self.git("show", "vanished:b.txt"), "vanished\n")
        self.assertNotIn("prunable", self.git("worktree", "list", "--porcelain"))

    def test_drop_aborts_when_the_index_cannot_be_read(self) -> None:
        path = self.feature("hurt")
        self.write("b.txt", "edited\n", cwd=str(path))
        self.corrupt_index(path)
        result = self.wt("drop", "hurt", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not inspect", result.stderr)
        self.assertTrue(path.exists())
        self.assertTrue(self.has_branch("hurt"))
        self.assertEqual(Path(path, "b.txt").read_text(), "edited\n")

    # land --------------------------------------------------------------------

    def test_land_fast_forwards_main_and_closes(self) -> None:
        path = self.feature("land-me")
        self.wt("land", "land-me")
        self.assertEqual(self.subject("main"), "land-me")
        self.assertFalse(path.exists())
        self.assertFalse(self.has_branch("land-me"))

    def test_land_from_inside_keeps_the_folder_open(self) -> None:
        path = self.feature("inside")
        self.wt("land", cwd=str(path))
        self.assertEqual(self.subject("main"), "inside")
        self.assertTrue(path.exists())
        self.assertTrue(self.entry("inside")["landed"])

    def test_land_refuses_a_wip_tip(self) -> None:
        path = self.new("wip")
        self.write("b.txt", "half\n", cwd=str(path))
        self.git("add", "-A", cwd=str(path))
        self.git("commit", "-qm", "wip: wip", "-m", "Wt-Wip: 1", cwd=str(path))
        result = self.wt("land", "wip", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wip commit", result.stderr)
        self.assertEqual(self.subject("main"), "base")

    def test_land_refuses_uncommitted_changes(self) -> None:
        path = self.feature("dirty")
        self.write("b.txt", "more\n", cwd=str(path))
        result = self.wt("land", "dirty", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.subject("main"), "base")

    def test_land_conflict_pauses_and_abort_restores(self) -> None:
        path = self.new("conflict")
        self.write("a.txt", "theirs\n", cwd=str(path))
        self.commit("theirs", cwd=str(path))
        self.write("a.txt", "ours\n")
        self.commit("ours")
        result = self.wt("land", "conflict", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rebase conflict", result.stderr)
        self.wt("land", "--abort", "conflict")
        self.assertEqual(self.git("status", "--porcelain", cwd=str(path)), "")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(path)).strip(), "conflict")

    def test_land_continue_finishes_a_paused_rebase(self) -> None:
        path = self.new("conflict")
        self.write("a.txt", "theirs\n", cwd=str(path))
        self.commit("theirs", cwd=str(path))
        self.write("a.txt", "ours\n")
        self.commit("ours")
        self.wt("land", "conflict", check=False)
        self.write("a.txt", "both\n", cwd=str(path))
        self.git("add", "a.txt", cwd=str(path))
        self.wt("land", "--continue", "conflict")
        self.assertEqual(Path(self.main, "a.txt").read_text(), "both\n")
        self.assertFalse(path.exists())

    def test_land_abort_on_conflict_restores_the_worktree(self) -> None:
        path = self.new("conflict")
        self.write("a.txt", "theirs\n", cwd=str(path))
        self.commit("theirs", cwd=str(path))
        self.write("a.txt", "ours\n")
        self.commit("ours")
        result = self.wt("land", "--abort-on-conflict", "conflict", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("status", "--porcelain", cwd=str(path)), "")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(path)).strip(), "conflict")

    def test_land_leaves_unrelated_uncommitted_main_changes_alone(self) -> None:
        self.feature("land-me")
        self.write("a.txt", "uncommitted\n")
        self.wt("land", "land-me")
        self.assertEqual(self.subject("main"), "land-me")
        self.assertEqual(Path(self.main, "a.txt").read_text(), "uncommitted\n")

    def test_land_refuses_when_the_branch_touches_dirty_main_paths(self) -> None:
        path = self.feature("land-me", filename="a.txt")
        self.write("a.txt", "uncommitted\n")
        result = self.wt("land", "land-me", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(path.exists())
        self.assertEqual(Path(self.main, "a.txt").read_text(), "uncommitted\n")
        self.assertEqual(self.subject("main"), "base")

    def test_land_refuses_an_untracked_path_it_would_overwrite_when_status_hides_untracked(self) -> None:
        self.git("config", "status.showUntrackedFiles", "no")
        path = self.feature("adds-b", filename="b.txt")
        self.write("b.txt", "mine, uncommitted\n")
        result = self.wt("land", "adds-b", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("b.txt", result.stderr)
        self.assertTrue(path.exists())
        self.assertEqual(Path(self.main, "b.txt").read_text(), "mine, uncommitted\n")
        self.assertEqual(self.subject("main"), "base")

    def test_land_aborts_when_the_commit_walk_fails_and_moves_nothing(self) -> None:
        path = self.new("corrupt")
        self.write("b.txt", "one\n", cwd=str(path))
        self.commit("one", cwd=str(path))
        self.write("c.txt", "two\n", cwd=str(path))
        self.commit("two", cwd=str(path))
        base = self.git("rev-parse", "main").strip()
        self.corrupt_loose_object(self.git("rev-parse", "HEAD~1", cwd=str(path)).strip())
        result = self.wt("land", "corrupt", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "main").strip(), base)
        self.assertTrue(path.exists())
        self.assertTrue(self.has_branch("corrupt"))

    def test_land_moves_only_the_ref_when_no_checkout_has_the_default(self) -> None:
        self.feature("land-me")
        self.git("switch", "-qc", "elsewhere")
        self.write("c.txt", "theirs, uncommitted\n")
        self.wt("land", "land-me")
        self.assertEqual(self.subject("main"), "land-me")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD").strip(), "elsewhere")
        self.assertFalse(Path(self.main, "b.txt").exists())

    def test_land_names_a_live_process_in_the_default_checkout(self) -> None:
        self.feature("land-me")
        process = self.sleeper(Path(self.main))
        result = self.wt("land", "land-me")
        self.assertIn(f"pid {process.pid}", result.stderr)
        self.assertTrue(Path(self.main, "b.txt").exists())

    def test_land_with_nothing_new_just_closes(self) -> None:
        path = self.new("idle")
        self.wt("land", "idle")
        self.assertFalse(path.exists())
        self.assertEqual(self.subject("main"), "base")

    # land from the primary checkout -------------------------------------------

    def topic(self, filename: str = "b.txt", text: str = "topic\n") -> None:
        """Put the primary checkout on a branch `topic` holding one commit, with main one commit further."""
        self.write("c.txt", "main\n")
        self.commit("moved on")
        self.git("switch", "-qc", "topic", "HEAD~1")
        self.write(filename, text)
        self.commit("topic")

    def test_land_from_the_root_lands_its_branch_and_returns_to_main(self) -> None:
        self.topic()
        self.write("d.txt", "someone else's\n")
        self.wt("land")
        self.assertEqual(self.current(), "main")
        self.assertEqual(self.subject("main"), "topic")
        self.assertEqual(self.subject("main~1"), "moved on")
        self.assertFalse(self.has_branch("topic"))
        self.assertEqual(Path(self.main, "d.txt").read_text(), "someone else's\n")

    def test_land_names_the_root_branch_from_a_worktree(self) -> None:
        self.topic()
        path = self.new("elsewhere")
        self.wt("land", "topic", cwd=str(path))
        self.assertEqual(self.current(), "main")
        self.assertEqual(self.subject("main"), "topic")

    def test_land_from_the_root_refuses_while_main_is_in_a_worktree(self) -> None:
        self.topic()
        self.git("worktree", "add", "-q", os.path.join(self.root, "holder"), "main")
        result = self.wt("land", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checked out in", result.stderr)
        self.assertEqual(self.current(), "topic")
        self.assertEqual(self.subject("main"), "moved on")

    def test_land_refuses_a_branch_checked_out_nowhere(self) -> None:
        self.git("branch", "loose")
        result = self.wt("land", "loose", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not checked out anywhere", result.stderr)

    def test_land_from_the_root_names_a_live_process(self) -> None:
        self.topic()
        process = self.sleeper(Path(self.main))
        result = self.wt("land")
        self.assertIn(f"pid {process.pid}", result.stderr)

    def test_land_from_the_root_refuses_to_rebase_over_a_dirty_path(self) -> None:
        self.topic()
        self.write("c.txt", "uncommitted\n")
        result = self.wt("land", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("c.txt", result.stderr)
        self.assertEqual(self.current(), "topic")
        self.assertEqual(Path(self.main, "c.txt").read_text(), "uncommitted\n")

    def test_land_from_the_root_continues_a_paused_rebase(self) -> None:
        self.write("a.txt", "ours\n")
        self.commit("ours")
        self.git("switch", "-qc", "topic", "HEAD~1")
        self.write("a.txt", "theirs\n")
        self.commit("topic")
        result = self.wt("land", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rebase conflict", result.stderr)
        self.write("a.txt", "both\n")
        self.git("add", "a.txt")
        self.wt("land", "--continue")
        self.assertEqual(self.current(), "main")
        self.assertEqual(self.subject("main"), "topic")
        self.assertEqual(Path(self.main, "a.txt").read_text(), "both\n")


class GitHub(Base):
    """The same repository with an origin remote and a fake `gh` first on PATH."""

    def setUp(self) -> None:
        super().setUp()
        origin = os.path.join(self.root, "origin.git")
        self.git("init", "-q", "--bare", origin)
        self.git("remote", "add", "origin", origin)
        self.git("push", "-q", "-u", "origin", "main")
        self.git("remote", "set-head", "origin", "main")
        self.state = Path(self.root, "gh")
        self.state.mkdir()
        bin_dir = Path(self.root, "bin")
        bin_dir.mkdir()
        fake = Path(__file__).resolve().with_name("fake_gh.py")
        Path(bin_dir, "gh").write_text(f'#!/bin/sh\nexec "{sys.executable}" "{fake}" "$@"\n')
        Path(bin_dir, "gh").chmod(0o755)
        self.env["PATH"] = f"{bin_dir}{os.pathsep}{self.env['PATH']}"
        self.env["FAKE_GH_DIR"] = str(self.state)
        self.env["WT_GH_POLL"] = "0.1"

    def calls(self) -> list[list[str]]:
        log = self.state / "calls.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def called(self, *prefix: str) -> list[list[str]]:
        return [call for call in self.calls() if call[: len(prefix)] == list(prefix)]

    def set_state(self, name: str, value) -> None:
        (self.state / name).write_text(json.dumps(value))

    def sha(self, ref: str) -> str:
        return self.git("rev-parse", ref).strip()

    def test_pr_opens_and_keeps_the_branch_until_it_merges(self) -> None:
        path = self.feature("proposal")
        self.wt("land", "--pr", "proposal")
        self.assertEqual(len(self.called("pr", "create")), 1)
        self.assertNotIn("--draft", self.called("pr", "create")[0])
        self.assertEqual(self.git("ls-remote", "origin", "proposal").split()[0], self.sha("proposal"))
        self.assertFalse(path.exists())
        self.assertTrue(self.has_branch("proposal"))
        self.set_state("merged.json", [["proposal", self.sha("proposal")]])
        self.new("other")
        self.wt("close", "other")
        self.assertFalse(self.has_branch("proposal"))
        self.assertEqual(self.wt("list", "--name").stdout.split(), [])

    def test_a_merged_pr_of_the_same_name_at_another_sha_keeps_the_branch(self) -> None:
        self.feature("reused")
        self.wt("close", "reused")
        self.set_state("merged.json", [["reused", "0" * 40]])
        self.new("other")
        self.wt("close", "other")
        self.assertTrue(self.has_branch("reused"))

    def test_draft_opens_a_draft(self) -> None:
        self.feature("sketch")
        self.wt("land", "--draft", "sketch")
        self.assertIn("--draft", self.called("pr", "create")[0])

    def test_green_auto_merges_when_the_base_requires_checks(self) -> None:
        self.feature("gated")
        self.set_state("rules.json", [{"type": "required_status_checks"}])
        self.wt("land", "--green", "gated")
        merges = self.called("pr", "merge")
        self.assertEqual(len(merges), 1)
        self.assertIn("--auto", merges[0])
        self.assertIn("--rebase", merges[0])
        self.assertTrue(self.has_branch("gated"))

    def test_green_waits_and_merges_when_nothing_is_required(self) -> None:
        path = self.feature("ungated")
        self.wt("land", "--green", "ungated")
        merges = self.called("pr", "merge")
        self.assertEqual(len(merges), 1)
        self.assertNotIn("--auto", merges[0])
        self.assertFalse(path.exists())
        self.assertFalse(self.has_branch("ungated"))

    def test_green_stops_on_failing_checks(self) -> None:
        self.feature("red")
        self.wt("land", "--pr", "red")
        prs = json.loads((self.state / "prs.json").read_text())
        prs[0]["statusCheckRollup"] = [{"name": "CI gate", "status": "COMPLETED", "conclusion": "FAILURE"}]
        self.set_state("prs.json", prs)
        self.new("red")
        result = self.wt("land", "--green", "red", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CI gate", result.stderr)
        self.assertEqual(self.called("pr", "merge"), [])

    def stacked(self) -> Path:
        path = self.feature("bottom")
        self.git("switch", "-qc", "top", cwd=str(path))
        self.write("c.txt", "top\n", cwd=str(path))
        self.commit("top", cwd=str(path))
        self.set_state(
            "stack.json",
            {"trunk": "main", "currentBranch": "top", "branches": [{"name": "bottom"}, {"name": "top"}]},
        )
        return path

    def test_a_stack_lands_locally_all_at_once(self) -> None:
        path = self.stacked()
        self.write("a.txt", "moved on\n")
        self.commit("moved on")
        self.git("switch", "-q", "bottom", cwd=str(path))
        self.wt("land", "bottom")
        self.assertEqual(self.subject("main"), "top")
        self.assertEqual(self.subject("main~1"), "bottom")
        self.assertFalse(path.exists())
        self.assertFalse(self.has_branch("bottom"))
        self.assertFalse(self.has_branch("top"))

    def test_a_stack_lands_through_gh_stack(self) -> None:
        path = self.stacked()
        self.wt("land", "--green", "bottom")
        submit = self.called("stack", "submit")
        self.assertEqual(len(submit), 1)
        self.assertIn("--open", submit[0])
        self.assertEqual(len(self.called("stack", "merge")), 1)
        self.assertFalse(path.exists())
        self.assertFalse(self.has_branch("bottom"))
        self.assertFalse(self.has_branch("top"))

    def test_a_closed_stack_keeps_its_layers_and_reopens_on_the_top(self) -> None:
        path = self.stacked()
        self.wt("close", "bottom")
        self.assertTrue(self.has_branch("bottom"))
        self.assertTrue(self.has_branch("top"))
        self.new("bottom")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(path)).strip(), "top")
        stderr = self.wt("drop", "bottom").stderr
        self.assertIn("dropped top", stderr)
        self.assertIn("dropped bottom", stderr)

    # land from the primary checkout -------------------------------------------

    def advance_origin(self, filename: str = "c.txt") -> None:
        """Put a commit on origin/main that local main does not have."""
        self.write(filename, "origin\n")
        self.commit("origin's")
        self.git("push", "-q", "origin", "main")
        self.git("reset", "-q", "--hard", "HEAD~1")

    def remote_sha(self, branch: str) -> str:
        out = self.git("ls-remote", "origin", f"refs/heads/{branch}").split()
        return out[0] if out else ""

    def test_root_on_main_pushes_its_commits(self) -> None:
        self.write("b.txt", "mine\n")
        self.commit("mine")
        self.wt("land")
        self.assertEqual(self.remote_sha("main"), self.sha("main"))

    def test_root_on_main_rebases_onto_origin_only_with_rebase(self) -> None:
        self.advance_origin()
        self.write("b.txt", "mine\n")
        self.commit("mine")
        self.write("a.txt", "someone else's\n")
        result = self.wt("land", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--rebase", result.stderr)
        self.assertEqual(self.subject(self.remote_sha("main")), "origin's")
        self.wt("land", "--rebase")
        self.assertEqual(self.remote_sha("main"), self.sha("main"))
        self.assertEqual(self.subject("main"), "mine")
        self.assertEqual(self.subject("main~1"), "origin's")
        self.assertEqual(Path(self.main, "a.txt").read_text(), "someone else's\n")

    def test_root_on_main_refuses_to_rebase_over_a_dirty_path(self) -> None:
        self.advance_origin("c.txt")
        self.write("b.txt", "mine\n")
        self.commit("mine")
        self.write("c.txt", "uncommitted\n")
        result = self.wt("land", "--rebase", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("c.txt", result.stderr)
        self.assertEqual(Path(self.main, "c.txt").read_text(), "uncommitted\n")
        self.assertEqual(self.subject("main"), "mine")

    def test_root_on_main_moves_its_commits_to_a_branch_for_a_pr(self) -> None:
        self.write("b.txt", "mine\n")
        self.commit("mine")
        result = self.wt("land", "--pr", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--branch", result.stderr)
        self.wt("land", "--pr", "--branch", "feat/mine")
        self.assertEqual(self.current(), "feat/mine")
        self.assertEqual(self.sha("main"), self.sha("origin/main"))
        self.assertEqual(self.remote_sha("feat/mine"), self.sha("feat/mine"))
        self.assertEqual(self.subject("feat/mine"), "mine")
        self.assertEqual(len(self.called("pr", "create")), 1)
        self.assertTrue(Path(self.main, "b.txt").exists())

    def test_root_branch_stays_checked_out_while_its_draft_is_open(self) -> None:
        self.git("switch", "-qc", "topic")
        self.write("b.txt", "topic\n")
        self.commit("topic")
        self.wt("land", "--draft")
        self.assertIn("--draft", self.called("pr", "create")[0])
        self.assertEqual(self.current(), "topic")

    def test_root_branch_returns_to_main_once_its_pr_merges(self) -> None:
        self.git("switch", "-qc", "topic")
        self.write("b.txt", "topic\n")
        self.commit("topic")
        self.wt("land", "--green")
        self.assertEqual(len(self.called("pr", "merge")), 1)
        self.assertEqual(self.current(), "main")
        self.assertFalse(self.has_branch("topic"))

    def test_root_branch_rerun_returns_to_main_after_an_auto_merge(self) -> None:
        self.git("switch", "-qc", "topic")
        self.write("b.txt", "topic\n")
        self.commit("topic")
        self.set_state("rules.json", [{"type": "required_status_checks"}])
        self.wt("land", "--green")
        self.assertEqual(self.current(), "topic")
        prs = json.loads((self.state / "prs.json").read_text())
        prs[0]["state"] = "MERGED"
        self.set_state("prs.json", prs)
        self.wt("land", "--green")
        self.assertEqual(self.current(), "main")
        self.assertFalse(self.has_branch("topic"))

    def test_close_keeps_the_branch_when_gh_fails(self) -> None:
        path = self.feature("offline")
        self.env["FAKE_GH_FAIL"] = "1"
        self.wt("close", "offline")
        self.assertFalse(path.exists())
        self.assertTrue(self.has_branch("offline"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
