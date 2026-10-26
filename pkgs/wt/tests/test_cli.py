#!/usr/bin/env python3
"""CLI-level tests for wt against real temporary git repositories.

Run with `PYTHONPATH=pkgs/wt python3 pkgs/wt/tests/test_cli.py`, or as the flake
check `wt`, which runs the installed binary through WT_BIN.
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
                "WT_WORKTREE_ROOT": os.path.join(self.root, "trees"),
                "XDG_DATA_HOME": os.path.join(self.root, "data"),
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
            [*WT_CMD, *args],
            cwd=cwd or self.main,
            env=self.env,
            text=True,
            capture_output=True,
            check=check,
        )

    def git(self, *args: str, cwd: str | None = None, check: bool = True) -> str:
        return subprocess.run(
            ["git", *args],
            cwd=cwd or self.main,
            env=self.env,
            text=True,
            capture_output=True,
            check=check,
        ).stdout

    def write(self, name: str, text: str, cwd: str | None = None) -> None:
        Path(cwd or self.main, name).write_text(text)

    def commit(self, message: str, cwd: str | None = None) -> None:
        self.git("add", "-A", cwd=cwd)
        self.git("commit", "-qm", message, cwd=cwd)

    def create(self, name: str) -> Path:
        return Path(self.wt("create", name).stdout.strip())

    def status(self, *args: str) -> dict:
        return json.loads(self.wt("list", "--json", *args).stdout)

    def entry(self, name: str) -> dict:
        document = self.status()
        for row in document["repos"][0]["worktrees"]:
            if row["name"] == name:
                return row
        self.fail(f"no worktree {name} in {document}")

    # layout and discovery ----------------------------------------------------

    def test_create_is_outside_checkout_and_round_trips(self) -> None:
        path = self.create("feature")
        self.assertTrue(str(path).startswith(self.env["WT_WORKTREE_ROOT"]))
        self.assertFalse(str(path).startswith(self.main + os.sep))
        self.assertEqual(self.wt("cd", "feature").stdout.strip(), str(path))
        self.assertEqual(self.wt("names").stdout.split(), ["feature"])
        self.assertIn("feature", self.wt("list").stdout)

    def test_status_json_is_versioned_and_carries_both_rows(self) -> None:
        self.create("feature")
        document = self.status()
        self.assertEqual(document["version"], 1)
        repo = document["repos"][0]
        self.assertEqual(repo["defaultBranch"], "main")
        self.assertEqual(repo["main"], self.main)
        self.assertEqual([row["isMain"] for row in repo["worktrees"]], [True, False])

    def test_list_all_outside_a_checkout(self) -> None:
        self.create("feature")
        listing = self.wt("list", "--all", cwd=self.root).stdout
        self.assertIn("feature", listing)
        document = json.loads(self.wt("list", "--all", "--json", cwd=self.root).stdout)
        self.assertEqual(len(document["repos"]), 1)

    def test_dot_target_is_the_containing_worktree(self) -> None:
        path = self.create("feature")
        document = json.loads(self.wt("list", "--json", ".", cwd=str(path)).stdout)
        rows = document["repos"][0]["worktrees"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["name"], "feature")

    def test_same_basename_repositories_get_separate_roots(self) -> None:
        other = os.path.join(self.root, "elsewhere", "repo")
        os.makedirs(other)
        self.git("init", "-q", "-b", "main", cwd=other)
        self.git("config", "user.email", "test@example.com", cwd=other)
        self.git("config", "user.name", "Test", cwd=other)
        self.write("a.txt", "other\n", cwd=other)
        self.commit("other", cwd=other)
        first = self.create("feature")
        second = Path(self.wt("create", "feature", cwd=other).stdout.strip())
        self.assertNotEqual(first, second)
        document = json.loads(self.wt("list", "--all", "--json", cwd=self.root).stdout)
        self.assertEqual(len(document["repos"]), 2)
        for repo in document["repos"]:
            self.assertEqual(len(repo["worktrees"]), 2)

    def test_orphan_without_files_is_swept(self) -> None:
        trees = Path(self.env["WT_WORKTREE_ROOT"]) / "repo"
        orphan = trees / "leftover"
        orphan.mkdir(parents=True)
        self.wt("clean")
        self.assertFalse(orphan.exists())

    def test_orphan_with_files_needs_remove_force(self) -> None:
        trees = Path(self.env["WT_WORKTREE_ROOT"]) / "repo"
        orphan = trees / "leftover"
        orphan.mkdir(parents=True)
        (orphan / "note.txt").write_text("keep\n")
        self.wt("clean")
        self.assertTrue(orphan.exists())
        result = self.wt("remove", "leftover", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.wt("remove", "--force", "leftover")
        self.assertFalse(orphan.exists())
        self.wt("trash")
        self.assertIn("leftover", self.wt("trash", "--json").stdout)

    # cleanup and trash -------------------------------------------------------

    def test_clean_removes_only_finished_work(self) -> None:
        clean = self.create("clean-one")
        self.create("dirty-one")
        Path(clean, "note.txt").write_text("landed\n")
        self.commit("one", cwd=str(clean))
        self.git("merge", "--ff-only", "clean-one")
        dirty = self.create("dirty")
        Path(dirty, "a.txt").write_text("changed\n")
        unlanded = self.create("unlanded")
        Path(unlanded, "b.txt").write_text("work\n")
        self.commit("work", cwd=str(unlanded))
        self.wt("clean")
        self.assertFalse(clean.exists())
        self.assertTrue(dirty.exists())
        self.assertTrue(unlanded.exists())

    def test_clean_keeps_a_worktree_parked_on_default(self) -> None:
        self.git("checkout", "-qb", "scratch")
        path = Path(self.env["WT_WORKTREE_ROOT"]) / "repo" / "second-main"
        self.git("worktree", "add", str(path), "main")
        self.wt("clean")
        self.assertTrue(path.exists())
        self.wt("remove", "second-main")
        self.assertFalse(path.exists())

    def test_remove_refuses_dirty_without_force(self) -> None:
        path = self.create("dirty")
        Path(path, "a.txt").write_text("changed\n")
        result = self.wt("remove", "dirty", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(path.exists())

    def test_remove_takes_a_path_and_deletes_the_branch(self) -> None:
        path = self.create("by-path")
        self.wt("remove", str(path), cwd=self.root)
        self.assertFalse(path.exists())
        self.assertEqual(self.git("branch", "--list", "by-path").strip(), "")

    def test_remove_refuses_the_directory_it_is_run_from(self) -> None:
        path = self.create("self")
        result = self.wt("remove", "self", cwd=str(path), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inside worktree 'self'", result.stderr)
        self.assertTrue(path.exists())

    def test_remove_drops_a_stacked_worktree_with_nothing_of_its_own(self) -> None:
        base = self.create("base")
        Path(base, "b.txt").write_text("work\n")
        self.commit("work", cwd=str(base))
        stacked = Path(self.wt("create", "stacked", "base").stdout.strip())
        self.wt("remove", "stacked")
        self.assertFalse(stacked.exists())
        self.assertTrue(base.exists())

    def test_remove_keeps_a_stacked_worktree_with_its_own_commit(self) -> None:
        self.create("base")
        stacked = Path(self.wt("create", "stacked", "base").stdout.strip())
        Path(stacked, "c.txt").write_text("more\n")
        self.commit("more", cwd=str(stacked))
        result = self.wt("remove", "stacked", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(stacked.exists())

    def test_a_pushed_branch_is_not_held_by_its_own_remote(self) -> None:
        path = self.create("pushed")
        Path(path, "b.txt").write_text("work\n")
        self.commit("work", cwd=str(path))
        self.git("update-ref", "refs/remotes/origin/pushed", "pushed")
        result = self.wt("remove", "pushed", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(path.exists())

    def test_clean_keeps_one_of_two_worktrees_on_the_same_unlanded_commit(self) -> None:
        first = self.create("first")
        Path(first, "b.txt").write_text("work\n")
        self.commit("work", cwd=str(first))
        commit = self.git("rev-parse", "first").strip()
        second = Path(self.wt("create", "second", "first").stdout.strip())
        self.wt("clean")
        self.assertEqual(first.exists() + second.exists(), 1)
        self.assertNotEqual(self.git("branch", "--contains", commit).strip(), "")

    def test_clean_skips_the_worktree_it_is_run_from(self) -> None:
        path = self.create("self")
        Path(path, "note.txt").write_text("landed\n")
        self.commit("one", cwd=str(path))
        self.git("merge", "--ff-only", "self")
        self.wt("clean", cwd=str(path))
        self.assertTrue(path.exists())
        self.wt("clean")
        self.assertFalse(path.exists())

    def test_locked_worktree_is_refused_even_with_force(self) -> None:
        path = self.create("locked")
        self.git("worktree", "lock", str(path))
        result = self.wt("remove", "--force", "locked", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("locked", result.stderr)
        self.assertTrue(path.exists())
        self.git("worktree", "unlock", str(path))
        self.wt("remove", "locked")
        self.assertFalse(path.exists())

    def test_force_remove_archives_and_restore_brings_work_back(self) -> None:
        path = self.create("work")
        Path(path, "a.txt").write_text("changed\n")
        Path(path, "new.txt").write_text("untracked\n")
        self.wt("remove", "--force", "work")
        self.assertFalse(path.exists())
        entries = json.loads(self.wt("trash", "--json").stdout)["entries"]
        self.assertEqual(len(entries), 1)
        entry = entries[0]
        refs = self.git("for-each-ref", "--format=%(refname)", "refs/wt/trash")
        self.assertIn(entry["ref"], refs)
        self.wt("restore", entry["id"])
        self.assertEqual(Path(path, "a.txt").read_text(), "changed\n")
        self.assertEqual(Path(path, "new.txt").read_text(), "untracked\n")
        self.assertEqual(json.loads(self.wt("trash", "--json").stdout)["entries"], [])
        self.assertEqual(self.git("for-each-ref", "--format=%(refname)", "refs/wt/trash").strip(), "")

    def test_restore_refuses_collisions_unless_renamed(self) -> None:
        path = self.create("work")
        Path(path, "a.txt").write_text("changed\n")
        self.wt("remove", "--force", "work")
        entry = json.loads(self.wt("trash", "--json").stdout)["entries"][0]
        self.create("work")
        result = self.wt("restore", entry["id"], check=False)
        self.assertNotEqual(result.returncode, 0)
        restored = Path(self.wt("restore", entry["id"], "--name", "work-2").stdout.strip())
        self.assertEqual(Path(restored, "a.txt").read_text(), "changed\n")

    def test_restore_keeps_a_slashed_branch_name(self) -> None:
        path = self.create("feat/one")
        self.assertEqual(path.name, "feat-one")
        Path(path, "a.txt").write_text("changed\n")
        self.wt("remove", "--force", "feat/one")
        entry = json.loads(self.wt("trash", "--json").stdout)["entries"][0]
        self.wt("restore", entry["id"])
        self.assertEqual(
            self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(path)).strip(), "feat/one"
        )

    def test_trash_purge_drops_the_ref(self) -> None:
        path = self.create("work")
        Path(path, "a.txt").write_text("changed\n")
        self.wt("remove", "--force", "work")
        entry = json.loads(self.wt("trash", "--json").stdout)["entries"][0]
        self.wt("trash", "purge", entry["id"])
        self.assertEqual(json.loads(self.wt("trash", "--json").stdout)["entries"], [])
        self.assertEqual(self.git("for-each-ref", "--format=%(refname)", "refs/wt/trash").strip(), "")

    # landed detection --------------------------------------------------------

    def test_cherry_picked_commits_count_as_landed(self) -> None:
        path = self.create("picked")
        Path(path, "b.txt").write_text("work\n")
        self.commit("work", cwd=str(path))
        self.git("cherry-pick", self.git("rev-parse", "picked", cwd=str(path)).strip())
        self.assertTrue(self.entry("picked")["landed"])
        self.assertTrue(self.entry("picked")["safeToRemove"])

    def test_squash_merge_counts_as_landed(self) -> None:
        path = self.create("squashed")
        Path(path, "b.txt").write_text("one\n")
        self.commit("one", cwd=str(path))
        Path(path, "b.txt").write_text("one\ntwo\n")
        self.commit("two", cwd=str(path))
        self.git("merge", "--squash", "squashed")
        self.git("commit", "-qm", "squash landed")
        self.assertTrue(self.entry("squashed")["landed"])
        self.wt("clean")
        self.assertFalse(path.exists())

    def test_binary_change_never_proves_a_squash(self) -> None:
        path = self.create("binary")
        Path(path, "blob.bin").write_bytes(b"\x00\x01")
        self.commit("binary", cwd=str(path))
        self.git("merge", "--squash", "binary")
        self.git("commit", "-qm", "squash landed")
        self.assertFalse(self.entry("binary")["landed"])

    # land --------------------------------------------------------------------

    def test_land_keeps_the_worktree(self) -> None:
        path = self.create("land-me")
        self.write("b.txt", "work\n", cwd=str(path))
        self.commit("work", cwd=str(path))
        self.wt("land", "land-me")
        self.assertTrue(path.exists())
        self.assertEqual(self.git("log", "--oneline", "-1").strip().split(" ", 1)[1], "work")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(path)).strip(), "land-me")
        landed = self.entry("land-me")
        self.assertTrue(landed["landed"])
        self.assertEqual(landed["ahead"], 0)

    def test_land_by_folder_refuses_a_folder_holding_another_branch(self) -> None:
        path = self.create("folder")
        self.git("switch", "-qc", "other", cwd=str(path))
        self.write("b.txt", "work\n", cwd=str(path))
        self.commit("work", cwd=str(path))
        result = self.wt("land", "folder", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wt land other", result.stderr)
        self.assertEqual(self.git("log", "--oneline", "-1").strip().split(" ", 1)[1], "base")
        self.wt("land", "other")
        self.assertEqual(self.git("log", "--oneline", "-1").strip().split(" ", 1)[1], "work")

    def test_land_takes_the_folder_name_of_a_slashed_branch(self) -> None:
        path = Path(self.wt("create", "feat/x").stdout.strip())
        self.write("b.txt", "work\n", cwd=str(path))
        self.commit("work", cwd=str(path))
        self.wt("land", "feat-x")
        self.assertEqual(self.git("log", "--oneline", "-1").strip().split(" ", 1)[1], "work")

    def test_land_conflict_pauses_and_abort_restores(self) -> None:
        path = self.create("conflict")
        Path(path, "a.txt").write_text("theirs\n")
        self.commit("theirs", cwd=str(path))
        Path(self.main, "a.txt").write_text("ours\n")
        self.commit("ours")
        result = self.wt("land", "conflict", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rebase conflict", result.stderr)
        self.assertTrue((path / ".git").exists())
        self.wt("land", "--abort", "conflict")
        self.assertEqual(self.git("status", "--porcelain", cwd=str(path)), "")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(path)).strip(), "conflict")

    def test_land_abort_on_conflict_restores_the_worktree(self) -> None:
        path = self.create("conflict")
        Path(path, "a.txt").write_text("theirs\n")
        self.commit("theirs", cwd=str(path))
        Path(self.main, "a.txt").write_text("ours\n")
        self.commit("ours")
        result = self.wt("land", "--abort-on-conflict", "conflict", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("status", "--porcelain", cwd=str(path)), "")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(path)).strip(), "conflict")

    def test_land_leaves_unrelated_uncommitted_main_changes_alone(self) -> None:
        path = self.create("land-me")
        self.write("b.txt", "work\n", cwd=str(path))
        self.commit("work", cwd=str(path))
        self.write("a.txt", "uncommitted\n")
        self.wt("land", "land-me")
        self.assertTrue(self.entry("land-me")["landed"])
        self.assertEqual(Path(self.main, "a.txt").read_text(), "uncommitted\n")
        self.assertIn("a.txt", self.git("status", "--porcelain"))

    def test_land_refuses_when_the_branch_touches_dirty_main_paths(self) -> None:
        path = self.create("land-me")
        self.write("a.txt", "branch\n", cwd=str(path))
        self.commit("branch change", cwd=str(path))
        self.write("a.txt", "uncommitted\n")
        result = self.wt("land", "land-me", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(path.exists())
        self.assertEqual(Path(self.main, "a.txt").read_text(), "uncommitted\n")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD").strip(), "main")

    def test_land_moves_only_the_ref_when_no_checkout_has_the_default(self) -> None:
        path = self.create("land-me")
        self.write("b.txt", "work\n", cwd=str(path))
        self.commit("work", cwd=str(path))
        self.git("switch", "-qc", "elsewhere")
        self.write("c.txt", "theirs, uncommitted\n")
        self.wt("land", "land-me")
        self.assertEqual(self.git("rev-parse", "main").strip(), self.git("rev-parse", "land-me").strip())
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD").strip(), "elsewhere")
        self.assertFalse(Path(self.main, "b.txt").exists())
        self.assertTrue(self.entry("land-me")["landed"])

    def test_land_names_a_live_process_in_the_default_checkout(self) -> None:
        path = self.create("land-me")
        self.write("b.txt", "work\n", cwd=str(path))
        self.commit("work", cwd=str(path))
        process = subprocess.Popen(["sleep", "30"], cwd=self.main)
        self.addCleanup(lambda: (process.kill(), process.wait()))
        time.sleep(0.2)
        result = self.wt("land", "land-me")
        self.assertIn(f"pid {process.pid}", result.stderr)
        self.assertTrue(Path(self.main, "b.txt").exists())

    # occupancy and locking ---------------------------------------------------

    def test_busy_worktree_is_skipped_and_remove_needs_the_override(self) -> None:
        path = self.create("busy")
        process = subprocess.Popen(["sleep", "30"], cwd=str(path))
        self.addCleanup(lambda: (process.kill(), process.wait()))
        time.sleep(0.2)
        self.assertTrue(self.entry("busy")["busy"])
        self.wt("clean")
        self.assertTrue(path.exists())
        self.assertNotEqual(self.wt("remove", "--force", "busy", check=False).returncode, 0)
        self.wt("remove", "--force", "--ignore-in-use", "busy")
        self.assertFalse(path.exists())

    def test_a_held_lock_makes_mutation_fail_without_changes(self) -> None:
        path = self.create("locked-out")
        holder = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import fcntl,sys,time;"
                f"h=open({str(Path(self.main, '.git', 'wt.lock'))!r}, 'a+');"
                "fcntl.flock(h, fcntl.LOCK_EX);"
                "print('ready', flush=True);"
                "time.sleep(30)",
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(lambda: (holder.kill(), holder.wait(), holder.stdout.close()))
        self.assertEqual(holder.stdout.readline().strip(), "ready")
        self.env["WT_LOCK_WAIT_SECONDS"] = "0.2"
        result = self.wt("remove", "locked-out", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("another wt is mutating", result.stderr)
        self.assertTrue(path.exists())

    # guard -------------------------------------------------------------------

    def test_guard_blocks_adds_and_moves_outside_the_root(self) -> None:
        blocked = [
            "git worktree add ../oops",
            "cd /tmp && git worktree add /tmp/oops",
            f"git worktree move {self.env['WT_WORKTREE_ROOT']}/repo/feature /tmp/oops",
            'git worktree add "$HOME/oops"',
        ]
        for command in blocked:
            with self.subTest(command=command):
                self.assertEqual(self.wt("guard", command, check=False).returncode, 1)
        allowed = [
            f"git worktree add {self.env['WT_WORKTREE_ROOT']}/repo/ok -b ok",
            f"git -C {self.main} worktree list",
        ]
        for command in allowed:
            with self.subTest(command=command):
                self.assertEqual(self.wt("guard", command, check=False).returncode, 0)

    def test_guard_resolves_relative_paths_against_git_c(self) -> None:
        inside_main = f"git -C {self.main} worktree add inside"
        self.assertEqual(self.wt("guard", inside_main, check=False).returncode, 1)
        in_root = f"git -C {self.env['WT_WORKTREE_ROOT']}/repo worktree add inside -b inside"
        self.assertEqual(self.wt("guard", in_root, check=False).returncode, 0)

    def test_guard_refuses_unresolved_dynamic_destinations(self) -> None:
        for command in ('git worktree add $(mktemp -d)', "git worktree add $DIR/x", "cd $X && git worktree add y"):
            with self.subTest(command=command):
                self.assertEqual(self.wt("guard", command, check=False).returncode, 1)

    def test_guard_lets_dynamic_directories_through_when_nothing_is_added(self) -> None:
        root = self.env["WT_WORKTREE_ROOT"]
        for command in (
            'cd "$HOME" && git worktree list',
            "P=/tmp; git -C $P log --oneline  # worktree",
            f"cd $X && git worktree add {root}/repo/ok -b ok",
        ):
            with self.subTest(command=command):
                self.assertEqual(self.wt("guard", command, check=False).returncode, 0)

    def test_guard_blocks_branch_switches_inside_a_worktree(self) -> None:
        path = self.create("feature")
        self.git("branch", "spare")
        blocked = [
            "git switch -c other",
            "git switch spare",
            "git checkout -b other",
            "git checkout spare",
            "git checkout -",
            f"cd {self.main} && git -C {path} switch spare",
        ]
        for command in blocked:
            with self.subTest(command=command):
                result = self.wt("guard", command, cwd=str(path), check=False)
                self.assertEqual(result.returncode, 1)
                self.assertIn("feature", result.stdout)
        allowed = ["git checkout -- a.txt", "git checkout a.txt", "git checkout spare -- a.txt", "git restore a.txt"]
        for command in allowed:
            with self.subTest(command=command):
                self.assertEqual(self.wt("guard", command, cwd=str(path), check=False).returncode, 0)

    def test_guard_lets_the_main_checkout_switch_branches(self) -> None:
        self.create("feature")
        for command in ("git switch -c other", "git checkout -b other", f"git -C {self.main} switch -c other"):
            with self.subTest(command=command):
                self.assertEqual(self.wt("guard", command, check=False).returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
