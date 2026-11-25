"""Regression checks for launch-time managed resource refresh (no real profiles touched)."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("agents_refresh", Path(__file__).with_name("agents-refresh.py"))
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)


class RefreshTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agents-refresh-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.profile = self.root / "profile"
        self.profile.mkdir()
        self.baseline = {"revision": "pin", "plugins": {
            "exa": {"pi": "/nix/store/exa-pin", "claude": None},
            "answer": {"pi": "/nix/store/answer-pin", "claude": "/nix/store/answer-claude"},
        }, "skills": {}}
        self.basefile = self.root / "baseline.json"
        self.basefile.write_text(json.dumps(self.baseline))
        self.settings = self.profile / "settings.json"
        self.settings.write_text(json.dumps({
            "packages": ["user-package", "/nix/store/exa-pin", "/nix/store/answer-pin", "core"],
            "piAgents": {"twinExtensions": ["/nix/store/exa-pin"], "maxWorkingAgents": 6},
            "model": "keep-me",
        }))
        self.env = {"AGENTS_HARNESS": "pi", "AGENTS_PROFILE": str(self.profile), "AGENTS_BASELINE": str(self.basefile)}

    def run_refresh(self, plugins):
        with patch.object(refresh, "resolve", return_value={"plugins": plugins, "skills": {}}):
            self.assertEqual(refresh.run(self.env), 0)
        return json.loads(self.settings.read_text())

    def test_only_existing_twins_are_updated(self):
        plugins = {**self.baseline["plugins"], "brand-new": {"pi": "/nix/store/new", "claude": None}}
        plugins["exa"] = {"pi": "/nix/store/exa-new", "claude": None}
        result = self.run_refresh(plugins)
        self.assertEqual(result["piAgents"]["twinExtensions"], ["/nix/store/exa-new"])
        self.assertEqual(result["piAgents"]["maxWorkingAgents"], 6)
        self.assertEqual(result["model"], "keep-me")
        self.assertIn("user-package", result["packages"])
        self.assertIn("core", result["packages"])
        self.assertIn("/nix/store/new", result["packages"])

    def test_reset_replaces_previous_override_instead_of_retaining_duplicate(self):
        plugins = dict(self.baseline["plugins"])
        plugins["exa"] = {"pi": "/nix/store/exa-local", "claude": None}
        self.run_refresh(plugins)
        manifest = json.loads((self.profile / refresh.MANIFEST).read_text())
        self.assertEqual(manifest["packages"]["exa"], "/nix/store/exa-local")
        result = self.run_refresh(self.baseline["plugins"])
        self.assertNotIn("/nix/store/exa-local", result["packages"])
        self.assertEqual(result["packages"].count("/nix/store/exa-pin"), 1)
        self.assertEqual(result["piAgents"]["twinExtensions"], ["/nix/store/exa-pin"])

    def test_claude_refresh_preserves_native_synced_data_and_user_skills(self):
        skills = self.profile / "skills"
        synced = skills / "synced"
        synced.mkdir(parents=True)
        (synced / "bucket").write_text("native state")
        custom = skills / "custom"
        custom.mkdir()
        (custom / "SKILL.md").write_text("user content")
        managed = skills / "demo"
        managed.mkdir()
        (managed / "SKILL.md").symlink_to("/nix/store/old/SKILL.md")
        refresh.sync_skills(self.profile, {"demo": "/nix/store/new-demo"}, set(), ("/nix/store/",))
        self.assertEqual((synced / "bucket").read_text(), "native state")
        self.assertEqual((custom / "SKILL.md").read_text(), "user content")
        self.assertEqual(managed.readlink(), Path("/nix/store/new-demo"))
        self.assertTrue(skills.stat().st_mode & 0o200, "native skill directory stays writable")

    def test_failed_claude_refresh_keeps_journal_for_later_reset(self):
        env = {**self.env, "AGENTS_HARNESS": "claude"}
        desired = {"plugins": {}, "skills": {"a": "/nix/store/a", "b": "/nix/store/b"}}
        symlink = refresh.os.symlink
        def fail_second(target, link):
            if Path(link).name == "b":
                raise OSError("simulated failure")
            return symlink(target, link)
        with patch.object(refresh, "resolve", return_value=desired), patch.object(refresh.os, "symlink", side_effect=fail_second):
            with self.assertRaises(refresh.Fail):
                refresh.run(env)
        self.assertTrue((self.profile / "skills/a").is_symlink())
        with patch.object(refresh, "resolve", return_value={"plugins": {}, "skills": {}}):
            refresh.run(env)
        self.assertFalse((self.profile / "skills/a").is_symlink())

    def test_pi_skill_refresh_uses_immutable_paths_and_preserves_user_entries(self):
        settings = {"skills": ["/user/skill", "!project-ignore/**"]}
        manifest = {}
        baseline = {"skills": {"demo": "/nix/store/pinned-demo"}}
        refresh.sync_pi_skills(settings, {"demo": "/nix/store/local-demo"}, baseline, manifest, "/home/test")
        self.assertIn("/nix/store/local-demo", settings["skills"])
        self.assertIn("-/home/test/.agents/skills/demo", settings["skills"])
        refresh.sync_pi_skills(settings, {"demo": "/nix/store/pinned-demo"}, baseline, manifest, "/home/test")
        self.assertNotIn("/nix/store/local-demo", settings["skills"])
        self.assertIn("/user/skill", settings["skills"])
        self.assertIn("!project-ignore/**", settings["skills"])

    def test_local_only_plugin_disappears_on_reset(self):
        plugins = {**self.baseline["plugins"], "brand-new": {"pi": "/nix/store/new", "claude": None}}
        self.run_refresh(plugins)
        result = self.run_refresh(self.baseline["plugins"])
        self.assertNotIn("/nix/store/new", result["packages"])


if __name__ == "__main__":
    unittest.main()
