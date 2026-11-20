"""Collect recorded documentation changes from local pi and Claude Code sessions."""

import argparse
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unicodedata


SUFFIXES = (".md", ".mdx", ".rst", ".adoc", ".asciidoc")
AGENT_DIRS = {
    ".git", "node_modules", ".agents", ".claude", ".claude-work", ".codex", ".pi",
    ".cursor", ".github-copilot", ".serena", ".sisyphus", ".planning",
    "skills", "agent-skills", "memory", "scratch", "scratchpad", "plans", "plan", "handoff", "handoffs",
    "work-items", "fixtures", "__fixtures__", "subagents",
}
AGENT_FILE = re.compile(
    r"^(copilot-instructions|handoffs?|plans?|"
    r"progress|todo|tasks?|memory|scratchpad|next-steps|research[-_.]notes|session[-_.]notes|agent[-_.]context)"
    r"(?:$|[._-])|(?:^|[-_.])(?:handoff|implementation-plan|plan)$"
)


def is_doc(path):
    path = Path(path)
    if path.name in {"AGENTS.md", "CLAUDE.md", "CLAUDE.local.md", "GEMINI.md", "SKILL.md", "REQUIREMENTS.md", "DISPATCH.md"}:
        return False
    if path.stem.casefold().startswith(("license", "licence")):
        return False
    parts = tuple(p.casefold() for p in path.parts)
    if not parts or AGENT_DIRS.intersection(parts[:-1]):
        return False
    if path.suffix.lower() not in SUFFIXES and parts[-1] not in {
        "readme", "readme.txt", "contributing", "contributing.txt", "changelog", "changelog.txt",
    }:
        return False
    if ".github" in parts and {"prompts", "instructions", "agents"}.intersection(parts):
        return False
    pairs = set(zip(parts, parts[1:]))
    if pairs.intersection({("pi", "agents"), ("agents", "store"), ("agents", "tmp"), ("claude-code", "context.md")}):
        return False
    if path.name.casefold().endswith((".prompt.md", ".instructions.md", ".agent.md")):
        return False
    return not AGENT_FILE.search(Path(parts[-1]).stem.lstrip("."))


def scratch_checkout(path):
    pairs = set(zip(path.parts, path.parts[1:]))
    return (bool(pairs & {("agents", "tmp"), ("agents", "store")})
            or "scratchpad" in path.parts or any(p.startswith("agent-tools-e2e-run-") for p in path.parts))


def visible(content):
    if isinstance(content, str):
        return content.strip()
    return "\n".join(b["text"] for b in content if b.get("type") == "text" and isinstance(b.get("text"), str)).strip()


def excerpt(text):
    return text if len(text) <= 900 else text[:899] + "…"


@lru_cache(maxsize=8192)
def repo_for(directory):
    for parent in (directory, *directory.parents):
        if (parent / ".git").exists():
            return parent
    return None


def edit_record(tool, args, result, cwd):
    file = args.get("file_path") or args.get("path") or result.get("filePath")
    if not isinstance(file, str) or "\0" in file:
        return
    path = Path(os.path.normpath(cwd / file))
    if scratch_checkout(path):
        return
    repo = repo_for(path.parent)
    if repo is None:
        # The worktree may have been removed since the session ran.
        if cwd.exists() or not path.is_relative_to(cwd):
            return
        if not is_doc(path):
            return
        repo = cwd
    if not is_doc(path.relative_to(repo)):
        return
    patch = result.get("patch") or result.get("diff")
    hunks = result.get("structuredPatch")
    if not patch and hunks:
        patch = "\n".join(
            f"@@ -{h['oldStart']},{h['oldLines']} +{h['newStart']},{h['newLines']} @@\n" + "\n".join(h["lines"])
            for h in hunks
        )
    if patch:
        return repo, str(path.relative_to(repo)), "Edit", patch
    if tool == "write":
        return repo, str(path.relative_to(repo)), "Written text · no prior snapshot", args.get("content", "")
    parts = []
    for edit in args.get("edits", [args]):
        old = edit.get("oldText", edit.get("old_string"))
        new = edit.get("newText", edit.get("new_string"))
        if isinstance(old, str) and isinstance(new, str):
            parts.extend(["@@ replacement @@", *("-" + line for line in old.splitlines()), *("+" + line for line in new.splitlines())])
    if parts:
        return repo, str(path.relative_to(repo)), "Edit", "\n".join(parts)


def committed_docs(command, output, cwd):
    if not re.search(r"\bgit\b[^\n;&|]*\bcommit\b", command):
        return
    match = re.search(r"^\[[^\]\n]+ ([a-f0-9]{7,64})\] .+", output, re.M)
    if not match:
        return
    sha = match[1]
    directory = cwd
    target = re.search(r"""\bgit\s+-C\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))""", command)
    if target:
        directory = cwd / next(group for group in target.groups() if group is not None)
    if not directory.is_dir():
        return
    repo = repo_for(directory)
    if repo is None or scratch_checkout(repo):
        return
    git = ["git", "--no-pager", "--literal-pathspecs", "-C", str(repo), "show", "--format=",
           "--no-renames", "--no-ext-diff", "--no-textconv"]
    names = subprocess.run([*git, "--name-only", "-z", sha], capture_output=True)
    if names.returncode:
        return
    for raw in names.stdout.split(b"\0"):
        file = os.fsdecode(raw)
        if not is_doc(file):
            continue
        diff = subprocess.run([*git, sha, "--", file], capture_output=True, encoding="utf8", errors="replace")
        if diff.returncode == 0 and diff.stdout.strip():
            yield repo, file, f"Commit {sha}", diff.stdout


def parse_session(path, agent, since):
    calls = {}
    cwd = None
    request = preceding_statement = ""
    with path.open("rb") as stream:
        for number, line in enumerate(stream, 1):
            try:
                row = json.loads(line)
            except (ValueError, UnicodeDecodeError):
                continue
            if row.get("cwd") and Path(row["cwd"]).is_absolute():
                cwd = Path(row["cwd"])
            message = row.get("message") or {}
            if not isinstance(message, dict):
                continue
            role = message.get("role")
            content = message.get("content", [])
            blocks = content if isinstance(content, list) else []
            if role == "user" and not any(b.get("type") == "tool_result" for b in blocks):
                text = visible(content)
                if text:
                    request = excerpt(text) if not text.startswith("<") else ""
                    preceding_statement = ""
            if role == "assistant":
                public_text = excerpt(visible(content))
                statement = public_text or preceding_statement
                for b in blocks:
                    name = str(b.get("name", "")).lower()
                    if b.get("type") in ("toolCall", "tool_use") and name in ("edit", "write", "bash"):
                        args = b.get("arguments", b.get("input", {}))
                        if isinstance(args, dict) and b.get("id"):
                            target = args.get("path") or args.get("file_path")
                            if name != "bash" and isinstance(target, str):
                                target_path = Path(target)
                                if not is_doc(target_path.name if target_path.is_absolute() else target_path):
                                    continue
                            calls[b["id"]] = (name, args, request, statement, cwd)
                preceding_statement = "" if any(b.get("type") in ("toolCall", "tool_use") for b in blocks) else public_text
            if role == "toolResult":
                results = [(message.get("toolCallId"), message.get("isError"), content)]
                details = message.get("details") or {}
            elif role == "user":
                results = [(b.get("tool_use_id"), b.get("is_error"), b.get("content", "")) for b in blocks if b.get("type") == "tool_result"]
                details = row.get("toolUseResult") or {}
            else:
                continue
            for call_id, failed, output in results:
                call = calls.pop(call_id, None)
                if failed or not call or not row.get("timestamp"):
                    continue
                stamp = datetime.fromisoformat(row["timestamp"])
                if stamp < since:
                    continue
                name, args, prompt, reason, original_dir = call
                directory = original_dir or cwd
                if not directory:
                    continue
                if name == "bash":
                    cmd = args.get("command", "")
                    if "commit" not in cmd:
                        continue
                    changes = committed_docs(cmd, visible(output), directory)
                else:
                    change = edit_record(name, args, details if isinstance(details, dict) else {}, directory)
                    changes = [change] if change else []
                for repo, file, kind, patch in changes:
                    identity = sha256(f"{agent}:{call_id}:{file}".encode()).hexdigest()[:24]
                    yield dict(id=identity, agent=agent, time=stamp, repo=str(repo), file=file, kind=kind,
                               patch=patch, request=prompt, statement=reason, session=path, line=number)


def terminal_text(value):
    return "".join(c if c in "\n\t" or unicodedata.category(c) not in ("Cc", "Cf", "Cs") else "�" for c in value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=7, help="look back this many days (default 7)")
    parser.add_argument("--repo", help="filter by checkout name or absolute path")
    parser.add_argument("--show", metavar="ID", help="show the diff, session and recorded context for an entry")
    parser.add_argument("--jsonl", action="store_true", help="emit matching records including their diffs")
    args = parser.parse_args()
    if args.days < 1:
        parser.error("--days must be positive")
    since = datetime.now(timezone.utc) - timedelta(days=args.days)
    home = Path.home()
    roots = [(p, "pi") for p in (home / ".pi").glob("*/sessions")]
    roots += [(p, "Claude") for p in home.glob(".claude*/projects")]
    events = {}
    scanned = set()
    for root, agent in roots:
        for path in root.rglob("*.jsonl"):
            try:
                path = path.resolve()
                if path in scanned or path.stat().st_mtime < since.timestamp():
                    continue
                scanned.add(path)
                for event in parse_session(path, agent, since):
                    if args.repo and args.repo not in (event["repo"], Path(event["repo"]).name):
                        continue
                    if not args.show or event["id"].startswith(args.show):
                        events.setdefault(event["id"], event)
            except FileNotFoundError:
                continue
    if args.show and len(events) != 1:
        parser.error(f"{len(events)} matches for {args.show}; check --days or use a longer ID")
    for e in sorted(events.values(), key=lambda e: e["time"], reverse=True):
        if args.jsonl:
            print(json.dumps({**e, "time": e["time"].isoformat(), "session": str(e["session"])}))
            continue
        label = f"{e['id'][:12]}  {e['time'].astimezone():%Y-%m-%d %H:%M}  {e['agent']:6}  {e['repo']}/{e['file']}  [{e['kind']}]"
        print(terminal_text(label))
        if args.show:
            print(terminal_text(f"Session: {e['session']}:{e['line']}\nRequest: {e['request'] or 'unrecorded'}\n"
                                f"Nearby agent statement: {e['statement'] or 'unrecorded'}\n\n{e['patch']}"))
    if not args.show and not args.jsonl:
        print(f"{len(events)} entries. Use --show ID for the diff and session.", file=sys.stderr)


if __name__ == "__main__":
    main()
