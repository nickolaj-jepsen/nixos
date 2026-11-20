import runpy
from pathlib import Path
import subprocess
import tempfile
import unittest


reporter = runpy.run_path(str(Path(__file__).resolve().parents[1] / "doc-edits.py"))


class DocumentationFilterTest(unittest.TestCase):
    def test_filter(self):
        for path in (
            "AGENTS.md", "packages/core/CLAUDE.md", "plans/README.md", ".handoff-report.md",
            "tasks/HANDOFF.md", "PROGRESS.md", ".agents/store/research/a.md",
            "skills/format/references/docs.md", ".github/instructions/types.instructions.md",
            "modules/programs/pi/agents/reviewer.md", "test/fixtures/README.md", "package.json",
        ):
            with self.subTest(path=path):
                self.assertFalse(reporter["is_doc"](path))
        for path in ("README", "docs/agents.md", "docs/notes.md", "plugins/docfix/README.md", "docs/guides/planning.rst"):
            with self.subTest(path=path):
                self.assertTrue(reporter["is_doc"](path))

    def test_direct_edits_use_repo_relative_paths_even_in_nested_worktrees(self):
        with tempfile.TemporaryDirectory() as sandbox:
            root = Path(sandbox) / ".claude/worktrees/project"
            (root / ".git").mkdir(parents=True)
            for path, keep in (("docs/agents.md", True), ("handoffs/week.md", False)):
                change = reporter["edit_record"]("write", {"path": str(root / path), "content": "body"}, {}, root)
                self.assertEqual(change is not None, keep)

    def test_mixed_commit_never_includes_excluded_hunks(self):
        with tempfile.TemporaryDirectory() as sandbox:
            root = Path(sandbox)
            subprocess.run(["git", "init", "-q", root], check=True)
            for name in ("README.md", "plans/README.md", "AGENTS.md"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name + "\n")
            git = ["git", "-C", str(root)]
            subprocess.run([*git, "add", "."], check=True)
            output = subprocess.check_output(
                [*git, "-c", "user.name=Fixture", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-m", "update"], text=True,
            )
            changes = list(reporter["committed_docs"]("git commit -m update", output, root))
            self.assertEqual([file for _, file, _, _ in changes], ["README.md"])
            self.assertNotIn("AGENTS.md", changes[0][3])
            self.assertNotIn("plans/", changes[0][3])


if __name__ == "__main__":
    unittest.main()
