#!/usr/bin/env python3
"""CLI behaviour: plan reports, apply rewrites, live sessions are left alone.

Run with `PYTHONPATH=pkgs/transcript-sweep python3 pkgs/transcript-sweep/tests/test_cli.py`,
or through `nix build .#transcript-sweep` (which also runs it against the
installed binary's module).
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from transcript_sweep import cli, live

TOKEN = "ghp_" + "a1B2" * 9
OLD = time.time() - 30 * 24 * 3600


def session(text: str, session_id: str = "sess-1") -> str:
    header = {"type": "session", "version": 3, "id": session_id, "timestamp": "2026-01-01T00:00:00.000Z", "cwd": "/repo"}
    message = {"type": "message", "id": "aaaa1111", "parentId": None, "timestamp": "2026-01-01T00:00:01.000Z",
               "message": {"role": "user", "content": [{"type": "text", "text": text}], "timestamp": 1}}
    return json.dumps(header) + "\n" + json.dumps(message) + "\n"


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / "sessions"
        self.registry = Path(self._tmp.name) / "registry"
        self.root.mkdir()
        self.registry.mkdir()
        self.addCleanup(self._tmp.cleanup)
        self._saved = live.REGISTRIES
        live.REGISTRIES = (str(self.registry),)
        self.addCleanup(self.restore)

    def restore(self) -> None:
        live.REGISTRIES = self._saved

    def write(self, name: str, text: str, age: float = OLD) -> Path:
        path = self.root / name
        path.write_text(session(text))
        os.utime(path, (age, age))
        return path

    def register_live(self, session_id: str) -> None:
        entry = {"pid": os.getpid(), "sessionId": session_id, "cwd": "/repo"}
        (self.registry / f"{os.getpid()}.json").write_text(json.dumps(entry))

    def invoke(self, *argv: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = cli.main([*argv, "--root", str(self.root)])
        return code, out.getvalue()


class Plan(Base):
    def test_reports_without_changing_anything(self) -> None:
        path = self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", f"token {TOKEN}")
        before = path.read_bytes()
        code, out = self.invoke("plan")
        self.assertEqual(code, 0)
        self.assertIn("github-token", out)
        self.assertIn("would rewrite 1 of 1 transcripts", out)
        self.assertEqual(path.read_bytes(), before)

    def test_report_never_prints_a_secret(self) -> None:
        self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", f"token {TOKEN}")
        _, out = self.invoke("plan")
        self.assertNotIn(TOKEN, out)
        self.assertIn("[redacted:github-token:", out)

    def test_check_exits_one_on_a_hit(self) -> None:
        self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", f"token {TOKEN}")
        code, _ = self.invoke("plan", "--check")
        self.assertEqual(code, 1)

    def test_check_exits_zero_when_clean(self) -> None:
        self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", "nothing here")
        code, out = self.invoke("plan", "--check")
        self.assertEqual(code, 0)
        self.assertIn("no secrets found", out)

    def test_json_is_machine_readable(self) -> None:
        self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", f"token {TOKEN}")
        _, out = self.invoke("plan", "--json")
        data = json.loads(out)
        self.assertEqual(data["total_hits"], 1)
        self.assertFalse(data["applied"])
        self.assertEqual(data["rules"]["github-token"]["hits"], 1)
        self.assertNotIn(TOKEN, out)

    def test_empty_root(self) -> None:
        code, out = self.invoke("plan")
        self.assertEqual(code, 0)
        self.assertIn("no secrets found", out)


class Apply(Base):
    def test_rewrites_in_place(self) -> None:
        path = self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", f"token {TOKEN}")
        code, out = self.invoke("apply")
        self.assertEqual(code, 0)
        self.assertIn("rewrote 1 of 1 transcripts", out)
        text = path.read_text()
        self.assertNotIn(TOKEN, text)
        self.assertIn("[redacted:github-token:", text)
        for line in text.splitlines():
            json.loads(line)

    def test_apply_is_idempotent(self) -> None:
        path = self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", f"token {TOKEN}")
        self.invoke("apply")
        after_first = path.read_bytes()
        os.utime(path, (OLD, OLD))  # as if the session had long since ended
        code, out = self.invoke("apply")
        self.assertEqual(code, 0)
        self.assertIn("no secrets found", out)
        self.assertEqual(path.read_bytes(), after_first)

    def test_values_from_a_file(self) -> None:
        path = self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", "wifi password is correct-horse-battery")
        values = Path(self._tmp.name) / "values"
        values.write_text("# from op\ncorrect-horse-battery\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = cli.main(["apply", "--root", str(self.root), "--values-from", str(values)])
        self.assertEqual(code, 0)
        self.assertIn("[redacted:value:", path.read_text())


class Live(Base):
    def test_fresh_transcript_is_skipped(self) -> None:
        path = self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", f"token {TOKEN}", age=time.time())
        code, out = self.invoke("apply")
        self.assertEqual(code, 0)
        self.assertIn("skipped 1 live", out)
        self.assertIn(TOKEN, path.read_text())

    def test_registered_session_is_skipped_even_when_old(self) -> None:
        path = self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", f"token {TOKEN}")
        self.register_live("sess-1")
        self.invoke("apply")
        self.assertIn(TOKEN, path.read_text())

    def test_force_rewrites_a_live_file(self) -> None:
        path = self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", f"token {TOKEN}", age=time.time())
        self.register_live("sess-1")
        code, out = self.invoke("apply", "--force")
        self.assertEqual(code, 0)
        self.assertNotIn(TOKEN, path.read_text())
        self.assertNotIn("skipped", out)

    def test_dead_pid_in_the_registry_does_not_count(self) -> None:
        path = self.write("2026-01-01T00-00-00-000Z_sess-1.jsonl", f"token {TOKEN}")
        entry = {"pid": 999999, "sessionId": "sess-1", "cwd": "/repo"}
        (self.registry / "999999.json").write_text(json.dumps(entry))
        self.invoke("apply")
        self.assertNotIn(TOKEN, path.read_text())

    def test_pi_header_id_counts_as_live(self) -> None:
        path = self.root / "2026-01-01T00-00-00-000Z_other.jsonl"
        path.write_text(session(f"token {TOKEN}", session_id="pi-sess"))
        os.utime(path, (OLD, OLD))
        self.register_live("pi-sess")
        # The registry speaks session ids, and a pi transcript is named after its
        # timestamp, so only the header can say.
        self.invoke("apply")
        self.assertIn(TOKEN, path.read_text())


class Spill(Base):
    def test_spilled_tool_output_is_swept_too(self) -> None:
        spill = self.root / "sess-1" / "tool-results"
        spill.mkdir(parents=True)
        path = spill / "bnu2xiydd.txt"
        path.write_text(f"token {TOKEN}\n")
        os.utime(path, (OLD, OLD))
        code, out = self.invoke("apply")
        self.assertEqual(code, 0)
        self.assertIn("rewrote 1 of 1 transcripts", out)
        self.assertNotIn(TOKEN, path.read_text())

    def test_live_spill_is_skipped_by_its_session_directory(self) -> None:
        spill = self.root / "sess-1" / "tool-results"
        spill.mkdir(parents=True)
        path = spill / "bnu2xiydd.txt"
        path.write_text(f"token {TOKEN}\n")
        os.utime(path, (OLD, OLD))
        self.register_live("sess-1")
        self.invoke("apply")
        self.assertIn(TOKEN, path.read_text())


if __name__ == "__main__":
    unittest.main()
