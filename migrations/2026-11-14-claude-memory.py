"""Move Claude Code auto-memory from ~/.claude{,-work}/projects/<cwd>/memory to
agents/claude-memory/<repo-id> under the data home, the directory the claude
wrappers pass as autoMemoryDirectory.

Several sources can land in one directory (worktrees, both profiles):
identical files merge, differing ones are kept under a suffixed name, and the
MEMORY.md indexes are joined without duplicate lines. Paths naming the old
directory are rewritten in the moved files. Projects outside git (the `global`
store) and empty memory dirs are left alone.
"""

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path

HOME = Path.home()
PROFILES = {".claude": "", ".claude-work": "work"}


def project_cwd(project: Path) -> Path | None:
    for transcript in sorted(project.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True):
        with transcript.open(errors="replace") as fh:
            for line in fh:
                if '"cwd"' not in line:
                    continue
                try:
                    cwd = json.loads(line).get("cwd")
                except json.JSONDecodeError:
                    continue
                if cwd:
                    return Path(cwd)
    return None


def sanitized(p: Path) -> str:
    return re.sub(r"[^a-zA-Z0-9]", "-", str(p))


def guess_cwd(project: Path) -> Path | None:
    """Claude Code's dir name is lossy; match it against directories that exist."""
    for pattern in ("*", "dev/*", "dev/*/projects/*", "worktrees/*/*"):
        for cand in HOME.glob(pattern):
            if cand.is_dir() and sanitized(cand) == project.name:
                return cand
    return None


def store_root(cwd: Path) -> Path | None:
    if not cwd.is_dir():
        return None
    out = subprocess.run(["agent-notes", "root"], cwd=cwd, capture_output=True, text=True)
    root = Path(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip() else None
    return None if root is None or root.name == "global" else root


def tilde(p: Path) -> str:
    return "~/" + str(p.relative_to(HOME)) if p.is_relative_to(HOME) else str(p)


def rewrite(text: str, old: Path, new: Path) -> str:
    for a, b in ((str(old), str(new)), (tilde(old), tilde(new))):
        text = text.replace(a + "/", b + "/").replace(a, b)
    return text


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true", help="report what would move")
    args = ap.parse_args()

    plan: dict[Path, list[tuple[Path, str]]] = {}
    for profile, tag in PROFILES.items():
        for mem in sorted((HOME / profile / "projects").glob("*/memory")):
            if not mem.is_dir() or not any(mem.iterdir()):
                continue
            cwd = project_cwd(mem.parent) or guess_cwd(mem.parent)
            root = store_root(cwd) if cwd else None
            if root is None:
                print(f"skip   {tilde(mem)}  (cwd {cwd or 'unknown'}: no repository store)")
                continue
            plan.setdefault(root.parent.parent / "claude-memory" / root.name, []).append((mem, tag))

    for dest, sources in plan.items():
        print(f"\n{tilde(dest)}")
        index_lines: list[str] = []
        if (dest / "MEMORY.md").exists():
            index_lines = (dest / "MEMORY.md").read_text().splitlines()
        renames: dict[str, str] = {}
        for src, tag in sources:
            print(f"  from {tilde(src)}")
            for f in sorted(src.rglob("*"), key=lambda p: (p.name == "MEMORY.md", p)):
                if f.is_dir():
                    continue
                rel = f.relative_to(src)
                text = rewrite(f.read_text(errors="surrogateescape"), src, dest)
                if rel == Path("MEMORY.md"):
                    for line in text.splitlines():
                        for a, b in renames.items():
                            line = line.replace(f"({a})", f"({b})")
                        if line.strip() and line in index_lines:
                            continue
                        if line.startswith("# ") and any(i.startswith("# ") for i in index_lines):
                            continue
                        index_lines.append(line)
                    continue
                target = dest / rel
                if target.exists():
                    if target.read_text(errors="surrogateescape") == text:
                        print(f"    same   {rel}")
                        continue
                    target = target.with_stem(f"{target.stem}-{tag or 'personal'}")
                    renames[str(rel)] = str(target.relative_to(dest))
                    print(f"    differs {rel} -> {target.relative_to(dest)}")
                else:
                    print(f"    move   {rel}")
                if not args.dry_run:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(text, errors="surrogateescape")
                    shutil.copystat(f, target)
        if not args.dry_run:
            dest.mkdir(parents=True, exist_ok=True)
            (dest / "MEMORY.md").write_text("\n".join(index_lines).rstrip("\n") + "\n")
            for src, _ in sources:
                shutil.rmtree(src)


if __name__ == "__main__":
    main()
