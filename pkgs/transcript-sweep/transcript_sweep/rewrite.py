"""Structure-preserving rewrites of agent transcripts.

A transcript is JSONL: one entry per line, linked by `id`/`parentId`. Redaction
replaces strings inside entries and nothing else, so the tree, the branch
structure, timestamps, roles, token counts and tool sequences all survive, and
`pi --resume` still opens the file. Unchanged lines are written back byte for
byte, so the diff of a sweep is exactly the secrets.
"""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from .rules import OPAQUE_KEYS, redact_text

SPILL_DIR = "tool-results"


@dataclass
class FileResult:
    path: Path
    entries: int = 0
    changed_entries: int = 0
    hits: dict[str, int] = field(default_factory=dict)
    samples: dict[str, str] = field(default_factory=dict)
    bad_lines: int = 0
    rewritten: bool = False
    skipped: str | None = None

    @property
    def total_hits(self) -> int:
        return sum(self.hits.values())


def _walk(
    node: object,
    literals: dict[str, str],
    hits: dict[str, int],
    samples: dict[str, str],
) -> tuple[object, bool]:
    """Redact every string in a parsed entry, leaving the shape alone."""
    if isinstance(node, str):
        new, found = redact_text(node, literals, samples)
        for rule, count in found.items():
            hits[rule] = hits.get(rule, 0) + count
        return new, new != node
    if isinstance(node, list):
        changed = False
        out = []
        for item in node:
            new, item_changed = _walk(item, literals, hits, samples)
            changed = changed or item_changed
            out.append(new)
        return out, changed
    if isinstance(node, dict):
        changed = False
        out = {}
        for key, value in node.items():
            if key in OPAQUE_KEYS:
                out[key] = value
                continue
            new, item_changed = _walk(value, literals, hits, samples)
            changed = changed or item_changed
            out[key] = new
        return out, changed
    return node, False


def _line(obj: object) -> bytes:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()


def header_id(path: Path) -> str | None:
    """The session id of a pi transcript, from its header line."""
    try:
        with path.open("rb") as handle:
            first = handle.readline()
    except OSError:
        return None
    try:
        entry = json.loads(first)
    except (ValueError, UnicodeDecodeError):
        return None
    if isinstance(entry, dict) and entry.get("type") == "session":
        value = entry.get("id")
        return value if isinstance(value, str) else None
    return None


def sweep_file(
    path: Path,
    literals: dict[str, str] | None = None,
    apply: bool = False,
) -> FileResult:
    """Scan one transcript; rewrite it in place when `apply` is set.

    Rewritten lines are re-parsed before the file is replaced, and the
    replacement is a rename, so a failure leaves the original intact.
    """
    result = FileResult(path=path)
    literals = literals or {}
    with path.open("rb") as handle:
        raw = handle.read()

    if is_spill(path):
        return _sweep_spill(path, raw, result, literals, apply)

    lines = raw.split(b"\n")
    out: list[bytes] = []
    for number, line in enumerate(lines):
        # `split` leaves "" for the trailing newline and for the final line of a
        # file that has none: both go back unchanged.
        if not line:
            out.append(line)
            continue
        try:
            entry = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            # Left byte-identical: a sweep must not make an unreadable line worse.
            result.bad_lines += 1
            out.append(line)
            continue
        result.entries += 1
        new_entry, changed = _walk(entry, literals, result.hits, result.samples)
        if not changed:
            out.append(line)
            continue
        new_line = _line(new_entry)
        if json.loads(new_line) != new_entry:  # pragma: no cover - belt and braces
            raise ValueError(f"{path}:{number + 1}: rewrite did not round-trip")
        result.changed_entries += 1
        out.append(new_line)

    if result.changed_entries and apply:
        _replace(path, b"\n".join(out))
        result.rewritten = True

    return result


def _sweep_spill(
    path: Path,
    raw: bytes,
    result: FileResult,
    literals: dict[str, str],
    apply: bool,
) -> FileResult:
    """Claude Code spills oversized tool output to a plain file beside the
    transcript and only references it, so the value is not in the JSONL at all.

    `surrogateescape` so an undecodable byte round-trips instead of being lost.
    """
    text = raw.decode("utf-8", errors="surrogateescape")
    new, found = redact_text(text, literals, result.samples)
    result.hits.update(found)
    if new != text:
        result.changed_entries = 1
        if apply:
            _replace(path, new.encode("utf-8", errors="surrogateescape"))
            result.rewritten = True
    return result


def _replace(path: Path, payload: bytes) -> None:
    """Write beside the target and rename, so a failure leaves it intact."""
    mode = path.stat().st_mode & 0o777
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".sweep")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def is_spill(path: Path) -> bool:
    return path.suffix == ".txt" and path.parent.name == SPILL_DIR


def session_of(path: Path) -> str | None:
    """The session a target belongs to: a spill file sits in a directory named
    after it, a pi transcript names it in its header, and Claude Code uses it as
    the file name."""
    if is_spill(path):
        return path.parent.parent.name or None
    return header_id(path)


def targets(roots: list[Path]) -> list[Path]:
    """Every file a sweep owns: JSONL transcripts and the tool output spilled
    beside them. Binaries Claude Code spills (pdf, png) are not text and are
    left alone."""
    found: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        found.extend(sorted(p for p in root.rglob("*.jsonl") if p.is_file()))
        found.extend(
            sorted(p for p in root.rglob(f"{SPILL_DIR}/*.txt") if p.is_file())
        )
    return found
