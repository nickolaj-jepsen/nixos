"""plan: what is in the transcripts. apply: replace the secrets in place."""

from __future__ import annotations

import argparse
import json
import os
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from . import live, rewrite
from .rules import MIN_LITERAL_LEN

DEFAULT_ROOTS = ("~/.pi/agent/sessions", "~/.claude/projects")


def human_size(count: int) -> str:
    value = float(count)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} GiB"


def load_values(path: str | None) -> dict[str, str]:
    """Secret values to match verbatim, one per line, from a file.

    For passwords and other values no pattern describes. Blank lines and `#`
    comments are skipped.
    """
    if not path:
        return {}
    literals: dict[str, str] = {}
    for line in Path(path).expanduser().read_text().splitlines():
        value = line.rstrip("\n")
        if not value or value.startswith("#"):
            continue
        if len(value) < MIN_LITERAL_LEN:
            print(f"transcript-sweep: ignoring {len(value)}-char value from {path}", file=sys.stderr)
            continue
        literals[value] = "value"
    return literals


def _job(job: tuple[Path, dict[str, str], bool]) -> rewrite.FileResult:
    path, literals, apply = job
    return rewrite.sweep_file(path, literals, apply=apply)


def collect(
    roots: list[Path],
    literals: dict[str, str],
    force: bool,
    apply: bool,
    jobs: int,
    verbose: bool,
    progress: bool,
) -> list[rewrite.FileResult]:
    """Sweep every transcript, in one pass, skipping what is still being written.

    Scanning and rewriting happen together: reading 7 GiB twice to print a plan
    first costs minutes, and each file is replaced atomically anyway.
    """
    files = rewrite.targets(roots)
    live_ids = set() if force else live.live_session_ids()
    results: list[rewrite.FileResult] = []
    pending: list[Path] = []
    for path in files:
        if not force:
            # Claude Code names a transcript after its session id; pi names it
            # after the timestamp, so only the header knows the id the registry
            # speaks.
            if live.is_live(path, live_ids, rewrite.session_of(path)):
                results.append(rewrite.FileResult(path=path, skipped="live session"))
                continue
        pending.append(path)

    # Transcripts are independent, and the parse is pure Python, so the cores
    # are the whole speedup. Small runs stay in-process: a fork costs more than
    # a handful of files.
    workers = max(1, min(jobs, len(pending) // 64 or 1))
    if progress and pending:
        print(f"  sweeping {len(pending)} transcripts with {workers} jobs", file=sys.stderr, flush=True)
    queue = [(path, literals, apply) for path in pending]
    if workers == 1:
        swept = [_job(job) for job in queue]
    else:
        with ProcessPoolExecutor(max_workers=workers) as pool:
            swept = list(pool.map(_job, queue, chunksize=8))
    for result in swept:
        if verbose and result.total_hits:
            print(f"  {result.total_hits:5d}  {result.path}", file=sys.stderr)
        results.append(result)
    return sorted(results, key=lambda r: str(r.path))


def report(results: list[rewrite.FileResult], roots: list[Path], applied: bool) -> dict[str, object]:
    """The numbers, masked: a report is meant to be pasted into a ticket or a log."""
    per_rule: dict[str, dict[str, object]] = {}
    files_changed = 0
    bad_lines = 0
    skipped = 0
    for result in results:
        if result.skipped:
            skipped += 1
            continue
        bad_lines += result.bad_lines
        if result.total_hits:
            files_changed += 1
        for rule, count in result.hits.items():
            entry = per_rule.setdefault(rule, {"hits": 0, "files": 0, "sample": None})
            entry["hits"] = int(entry["hits"]) + count
            entry["files"] = int(entry["files"]) + 1
            entry["sample"] = entry["sample"] or result.samples.get(rule)

    sizes = {}
    for root in roots:
        total = 0
        count = 0
        if root.is_dir():
            for path in root.rglob("*.jsonl"):
                try:
                    total += path.stat().st_size
                    count += 1
                except OSError:
                    continue
        sizes[str(root)] = {"files": count, "bytes": total}

    return {
        "applied": applied,
        "roots": sizes,
        "files_scanned": len([r for r in results if not r.skipped]),
        "files_with_hits": files_changed,
        "files_skipped": skipped,
        "unparseable_lines": bad_lines,
        "rules": per_rule,
        "total_hits": sum(int(v["hits"]) for v in per_rule.values()),
    }


def print_report(data: dict[str, object], results: list[rewrite.FileResult], verbose: bool) -> None:
    roots = data["roots"]
    assert isinstance(roots, dict)
    for root, info in roots.items():
        assert isinstance(info, dict)
        print(f"  {root}  {info['files']} files, {human_size(int(info['bytes']))}")
    print()
    rules = data["rules"]
    assert isinstance(rules, dict)
    if not rules:
        print("  no secrets found")
    else:
        width = max(len(name) for name in rules)
        print(f"  {'rule':{width}}  hits  files  sample")
        for rule in sorted(rules):
            entry = rules[rule]
            assert isinstance(entry, dict)
            print(f"  {rule:{width}}  {entry['hits']:4d}  {entry['files']:5d}  {entry['sample']}")
    print()
    verb = "rewrote" if data["applied"] else "would rewrite"
    print(
        f"  {verb} {data['files_with_hits']} of {data['files_scanned']} transcripts"
        f" ({data['total_hits']} secrets)"
        + (f"; skipped {data['files_skipped']} live" if data["files_skipped"] else "")
        + (f"; {data['unparseable_lines']} lines left unreadable" if data["unparseable_lines"] else "")
    )
    if verbose and data["applied"]:
        for result in results:
            if result.rewritten:
                print(f"  {result.total_hits:5d}  {result.path}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="transcript-sweep",
        description="Replace secrets in agent transcripts without losing the transcripts.",
    )
    sub = parser.add_subparsers(dest="action", required=True)
    for name, help_text in (
        ("plan", "count what a sweep would replace; changes nothing"),
        ("apply", "replace the secrets in place"),
    ):
        command = sub.add_parser(name, help=help_text)
        command.add_argument(
            "--root",
            action="append",
            metavar="DIR",
            help=f"transcript tree to sweep; repeatable (default: {' and '.join(DEFAULT_ROOTS)})",
        )
        command.add_argument(
            "--values-from",
            metavar="FILE",
            help="match these secret values verbatim, one per line (for passwords no pattern knows)",
        )
        command.add_argument("--force", action="store_true", help="also rewrite live sessions")
        command.add_argument("--verbose", "-v", action="store_true", help="one line per transcript")
        command.add_argument(
            "--jobs",
            type=int,
            default=min(os.cpu_count() or 1, 8),
            metavar="N",
            help="transcripts to parse at once (default: the cores)",
        )
        command.add_argument("--json", action="store_true", help="machine-readable output")
        command.add_argument("--quiet", "-q", action="store_true", help="no progress on stderr")
        command.add_argument("--check", action="store_true", help="plan only: exit 1 if anything matched")

    args = parser.parse_args(argv)
    roots = [Path(r).expanduser() for r in (args.root or DEFAULT_ROOTS)]
    literals = load_values(args.values_from)
    progress = not args.quiet and sys.stderr.isatty()

    results = collect(
        roots,
        literals,
        force=args.force,
        apply=args.action == "apply",
        jobs=args.jobs,
        verbose=args.verbose,
        progress=progress,
    )

    data = report(results, roots, applied=args.action == "apply")
    if args.json:
        print(json.dumps(data, indent=2))
    else:
        print_report(data, results, args.verbose)

    if args.check and args.action == "plan" and data["total_hits"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
