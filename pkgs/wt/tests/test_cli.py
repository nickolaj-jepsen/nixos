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


class Fixture(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
