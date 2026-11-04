#!/usr/bin/env python3
"""File-level behaviour: what a rewrite keeps, and what it refuses to touch.

Run with `PYTHONPATH=pkgs/transcript-sweep python3 pkgs/transcript-sweep/tests/test_rewrite.py`,
or through `nix build .#transcript-sweep`.
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from transcript_sweep import rewrite

TOKEN = "ghp_" + "a1B2" * 9
KEY = (
    "-----BEGIN OPENSSH PRIVATE KEY-----\n"
    "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n"
    "-----END OPENSSH PRIVATE KEY-----"
)


def header(session_id: str = "abc-123") -> dict[str, object]:
    return {"type": "session", "version": 3, "id": session_id, "timestamp": "2026-01-01T00:00:00.000Z", "cwd": "/repo"}


def user(text: str, entry_id: str = "aaaa1111", parent: str | None = None) -> dict[str, object]:
    return {
        "type": "message",
        "id": entry_id,
        "parentId": parent,
        "timestamp": "2026-01-01T00:00:01.000Z",
        "message": {"role": "user", "content": [{"type": "text", "text": text}], "timestamp": 1},
    }


def tool_result(text: str, entry_id: str = "bbbb2222", parent: str = "aaaa1111") -> dict[str, object]:
    return {
        "type": "message",
        "id": entry_id,
        "parentId": parent,
        "timestamp": "2026-01-01T00:00:02.000Z",
        "message": {
            "role": "toolResult",
            "toolCallId": "call-1",
            "toolName": "read",
            "content": [{"type": "text", "text": text}],
            "isError": False,
            "timestamp": 2,
        },
    }


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def write(self, entries: list[dict[str, object]], name: str = "2026-01-01T00-00-00-000Z_abc-123.jsonl") -> Path:
        path = self.dir / name
        path.write_text("\n".join(json.dumps(entry) for entry in entries) + "\n")
        return path

    def read(self, path: Path) -> list[dict[str, object]]:
        return [json.loads(line) for line in path.read_text().splitlines()]


class Structure(Base):
    def test_tree_and_metadata_survive(self) -> None:
        path = self.write([header(), user("cat the key"), tool_result(f"export GITHUB_TOKEN={TOKEN}\n{KEY}")])
        before = self.read(path)
        result = rewrite.sweep_file(path, apply=True)

        after = self.read(path)
        self.assertTrue(result.rewritten)
        self.assertEqual(result.hits, {"private-key": 1, "github-token": 1})
        self.assertEqual(len(after), len(before))
        for old, new in zip(before, after, strict=True):
            self.assertEqual({k: v for k, v in old.items() if k != "message"}, {k: v for k, v in new.items() if k != "message"})
            if "message" in old:
                self.assertEqual(old["message"]["role"], new["message"]["role"])  # type: ignore[index]
        self.assertEqual(after[0], before[0])
        self.assertIn("cat the key", json.dumps(after[1]))

    def test_only_the_secret_changes(self) -> None:
        path = self.write([header(), tool_result(f"line one\n{TOKEN}\nline three")])
        before = self.read(path)[1]
        rewrite.sweep_file(path, apply=True)
        after = self.read(path)[1]
        old_text = before["message"]["content"][0]["text"]  # type: ignore[index]
        new_text = after["message"]["content"][0]["text"]  # type: ignore[index]
        self.assertTrue(new_text.startswith("line one\n"))
        self.assertTrue(new_text.endswith("\nline three"))
        self.assertEqual(len(old_text.splitlines()), len(new_text.splitlines()))

    def test_opaque_keys_are_left_alone(self) -> None:
        # A thinking signature is replayed verbatim; rewriting it would break the
        # session, and it cannot hold transcript text.
        entry = user("hi")
        entry["message"]["content"].append(  # type: ignore[index]
            {"type": "thinking", "thinking": TOKEN, "thinkingSignature": f"sig:{TOKEN}"}
        )
        path = self.write([header(), entry])
        rewrite.sweep_file(path, apply=True)
        block = self.read(path)[1]["message"]["content"][1]  # type: ignore[index]
        self.assertEqual(block["thinkingSignature"], f"sig:{TOKEN}")
        self.assertNotIn(TOKEN, block["thinking"])

    def test_plan_touches_nothing(self) -> None:
        path = self.write([header(), user(TOKEN)])
        before = path.read_bytes()
        result = rewrite.sweep_file(path, apply=False)
        self.assertEqual(result.total_hits, 1)
        self.assertFalse(result.rewritten)
        self.assertEqual(path.read_bytes(), before)

    def test_clean_file_is_not_rewritten(self) -> None:
        path = self.write([header(), user("nothing to see")])
        before = path.read_bytes()
        os.utime(path, (1, 1))
        result = rewrite.sweep_file(path, apply=True)
        self.assertFalse(result.rewritten)
        self.assertEqual(path.read_bytes(), before)


class Robustness(Base):
    def test_unparseable_line_is_preserved(self) -> None:
        path = self.dir / "broken.jsonl"
        path.write_text(json.dumps(header()) + "\n{not json\n" + json.dumps(user(TOKEN)) + "\n")
        result = rewrite.sweep_file(path, apply=True)
        lines = path.read_text().splitlines()
        self.assertEqual(result.bad_lines, 1)
        self.assertEqual(lines[1], "{not json")
        self.assertNotIn(TOKEN, lines[2])

    def test_no_trailing_newline(self) -> None:
        path = self.dir / "no-newline.jsonl"
        path.write_text(json.dumps(header()) + "\n" + json.dumps(user(TOKEN)))
        rewrite.sweep_file(path, apply=True)
        text = path.read_text()
        self.assertFalse(text.endswith("\n"))
        self.assertNotIn(TOKEN, text)

    def test_mode_is_kept(self) -> None:
        path = self.write([header(), user(TOKEN)])
        path.chmod(0o600)
        rewrite.sweep_file(path, apply=True)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_unicode_survives(self) -> None:
        path = self.write([header(), user("æøå — ✓ " + TOKEN)])
        rewrite.sweep_file(path, apply=True)
        text = path.read_text()
        self.assertIn("æøå — ✓", text)
        self.assertNotIn(TOKEN, text)

    def test_no_temporary_file_is_left_behind(self) -> None:
        path = self.write([header(), user(TOKEN)])
        rewrite.sweep_file(path, apply=True)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), [path.name])


class Literals(Base):
    def test_value_from_a_list(self) -> None:
        path = self.write([header(), user("the wifi password is correct-horse")])
        result = rewrite.sweep_file(path, literals={"correct-horse": "value"}, apply=True)
        self.assertEqual(result.hits, {"value": 1})
        self.assertNotIn("correct-horse", path.read_text())


class Header(Base):
    def test_session_id(self) -> None:
        path = self.write([header("01a1a75e-8a33-74dc")])
        self.assertEqual(rewrite.header_id(path), "01a1a75e-8a33-74dc")

    def test_claude_style_entry_has_no_session_header(self) -> None:
        path = self.dir / "claude.jsonl"
        path.write_text(json.dumps({"type": "user", "sessionId": "x", "message": {"role": "user"}}) + "\n")
        self.assertIsNone(rewrite.header_id(path))


class Spill(Base):
    def spill(self, text: str, name: str = "bnu2xiydd.txt") -> Path:
        directory = self.dir / "sess-1" / rewrite.SPILL_DIR
        directory.mkdir(parents=True)
        path = directory / name
        path.write_text(text)
        return path

    def test_oversized_tool_output_is_redacted(self) -> None:
        path = self.spill(f"cat ~/.ssh/id_ed25519\n{KEY}\n")
        result = rewrite.sweep_file(path, apply=True)
        self.assertEqual(result.hits, {"private-key": 1})
        text = path.read_text()
        self.assertIn("cat ~/.ssh/id_ed25519", text)
        self.assertNotIn("b3BlbnNzaC1rZXkt", text)

    def test_spill_is_found_and_binaries_are_not(self) -> None:
        path = self.spill("x")
        (path.parent / "report.pdf").write_text("not text")
        self.assertEqual(rewrite.targets([self.dir]), [path])

    def test_spill_belongs_to_its_session_directory(self) -> None:
        path = self.spill("x")
        self.assertEqual(rewrite.session_of(path), "sess-1")

    def test_undecodable_bytes_survive(self) -> None:
        path = self.spill("")
        path.write_bytes(b"\xff\xfe raw \xff " + TOKEN.encode())
        rewrite.sweep_file(path, apply=True)
        raw = path.read_bytes()
        self.assertIn(b"\xff\xfe raw \xff", raw)
        self.assertNotIn(TOKEN.encode(), raw)

    def test_unchanged_spill_is_not_rewritten(self) -> None:
        path = self.spill("nothing here")
        result = rewrite.sweep_file(path, apply=True)
        self.assertFalse(result.rewritten)


class Discovery(Base):
    def test_finds_jsonl_recursively_and_skips_other_files(self) -> None:
        (self.dir / "a").mkdir()
        (self.dir / "a" / "one.jsonl").write_text("{}\n")
        (self.dir / "two.txt").write_text("ignored\n")
        found = rewrite.targets([self.dir])
        self.assertEqual([p.name for p in found], ["one.jsonl"])

    def test_missing_root_is_not_an_error(self) -> None:
        self.assertEqual(rewrite.targets([self.dir / "nope"]), [])


if __name__ == "__main__":
    unittest.main()
