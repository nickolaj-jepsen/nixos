"""Undo what the agent-notes tool laid out, now that the agents flake's notes plugin links
`.agents/store` itself and Claude keeps its memory where it always did.

0. Refuses to run while a `claude` process exists (it writes the folders being moved) and exits
   non-zero, so activation runs it again next time.
1. Memory under agents/claude-memory/<id> (data home) moves into Claude's own
   <config dir>/projects/<slug>/memory, where <slug> is the main checkout's path as Claude Code
   names project folders (see `slug_of`). <config dir> is ~/.claude-work when it has
   projects/<slug>, else ~/.claude. An id is tied to a checkout by recomputing the old tool's
   id (`<basename>-<sha256(realpath(main))[:8]>`) for every main checkout under the project
   roots; a `.agents/claude-memory` link into an id is only a fallback for checkouts elsewhere.
   An id no checkout maps to stays where it is and is listed. Per id the files are planned
   first: if any file would clash with a different file at the destination, nothing of that id
   moves and the clashes are listed. A byte-identical file counts as moved.
2. In each such checkout and its worktrees the links `.agents/tmp`, `.agents/workflows` and
   `.agents/claude-memory` are removed, only when they are symlinks into the old locations, and
   `.agents` goes if that leaves it empty. `.agents/store` stays: the plugin owns it now.

Nothing else is deleted: scratch under state/agents/tmp, the store, and the emptied memory
folders are for the owner. Re-running finds nothing left to do.
"""

import argparse
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share")
STATE = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state")
MEMORY_ROOT = DATA / "agents/claude-memory"
STORE_ROOT = DATA / "agents/store"
TMP_ROOT = STATE / "agents/tmp"
PROC = Path("/proc")

# Where checkouts live, and how deep below each to look; HOME itself only for its own `.agents`.
ROOTS = [(HOME, 0), (HOME / "nixos", 3), (HOME / "dev", 3), (HOME / "worktrees", 3)]
SKIP = {"node_modules", "target", "result", "__pycache__"}
CLAUDE_DIRS = [HOME / ".claude-work", HOME / ".claude"]
MAX_SLUG = 200  # Claude Code 2.1.330: a longer name is cut to this and given a hash suffix.

errors = 0


def tilde(p: Path) -> str:
    return "~/" + str(p.relative_to(HOME)) if p.is_relative_to(HOME) else str(p)


def claude_running() -> bool:
    """True when a Claude Code process exists (Linux: /proc; elsewhere `pgrep -x claude` if present)."""
    if PROC.is_dir():
        name = re.compile(r"\.?claude(-wrapped_?)?")
        for entry in PROC.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                comm = (entry / "comm").read_text().strip()
                cmdline = (entry / "cmdline").read_bytes().split(b"\0")
                argv = [os.path.basename(a.decode(errors="replace")) for a in cmdline]
            except OSError:
                continue
            if name.fullmatch(comm) or (argv and name.fullmatch(argv[0])):
                return True
            if len(argv) > 1 and argv[0] in ("node", "bun") and argv[1] in ("claude", "cli.js", "cli.mjs"):
                return True
        return False
    if shutil.which("pgrep"):
        return subprocess.run(["pgrep", "-x", "claude"], capture_output=True).returncode == 0
    return False


def checkout_candidates() -> list[Path]:
    """Directories under the project roots that are a checkout or hold an `.agents` folder."""
    found: list[Path] = []
    seen: set[Path] = set()
    for root, depth in ROOTS:
        if not root.is_dir():
            continue
        base = len(root.parts)
        for dirpath, dirnames, _ in os.walk(root):
            here = Path(dirpath)
            level = len(here.parts) - base
            dirnames[:] = [
                d
                for d in sorted(dirnames)
                if level < depth
                and d not in SKIP
                and not d.startswith(".")
                and not d.startswith("result")
                and not (here / d).is_symlink()
            ]
            if here not in seen and ((here / ".git").exists() or (here / ".agents").is_dir()):
                seen.add(here)
                found.append(here)
    return found


def worktrees(checkout: Path) -> list[Path]:
    """The checkout's repository's worktrees, main first; empty when it is not a repository."""
    out = subprocess.run(
        ["git", "-C", str(checkout), "-c", "safe.directory=*", "worktree", "list", "--porcelain"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        return []
    return [Path(line[len("worktree ") :]) for line in out.stdout.splitlines() if line.startswith("worktree ")]


def link_target(link: Path) -> Path:
    return Path(os.path.normpath(link.parent / os.readlink(link)))


def retired(link: Path, name: str) -> bool:
    """True for a symlink into the place the old tool pointed `.agents/<name>` at."""
    if not link.is_symlink():
        return False
    target = link_target(link)
    if name == "tmp":
        return target.is_relative_to(TMP_ROOT)
    if name == "claude-memory":
        return target.is_relative_to(MEMORY_ROOT)
    return target.parent.parent == STORE_ROOT and target.name == "workflows"


def has_files(folder: Path) -> bool:
    return any(p.is_file() or p.is_symlink() for p in folder.rglob("*"))


def old_repo_id(main: Path) -> str:
    """The id agent-notes' `repo_id` gave the repository whose main checkout is `main` (a real path)."""
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", main.name).strip("-.") or "repo"
    return f"{name}-{hashlib.sha256(str(main).encode()).hexdigest()[:8]}"


def slug_of(path: str) -> str:
    """Claude Code's project folder name: `path.replace(/[^a-zA-Z0-9]/g, "-")` over UTF-16 code units
    (a character above U+FFFF becomes two dashes); past MAX_SLUG units it is cut and followed by
    `-` and `Math.abs(h).toString(36)` of the JavaScript string hash `h = h * 31 + unit | 0`."""
    raw = path.encode("utf-16-le", "surrogatepass")
    units = struct.unpack(f"<{len(raw) // 2}H", raw)
    slug = "".join(chr(u) if 48 <= u <= 57 or 65 <= u <= 90 or 97 <= u <= 122 else "-" for u in units)
    if len(slug) <= MAX_SLUG:
        return slug
    h = 0
    for u in units:
        h = (h * 31 + u) & 0xFFFFFFFF
    if h >= 0x80000000:
        h -= 0x100000000
    n, digits = abs(h), ""
    while True:
        n, r = divmod(n, 36)
        digits = "0123456789abcdefghijklmnopqrstuvwxyz"[r] + digits
        if n == 0:
            break
    return f"{slug[:MAX_SLUG]}-{digits}"


def destination(main: Path) -> Path:
    slug = slug_of(str(main))
    for config in CLAUDE_DIRS:
        if (config / "projects" / slug).is_dir():
            return config / "projects" / slug / "memory"
    return CLAUDE_DIRS[-1] / "projects" / slug / "memory"


def partial_of(target: Path) -> Path:
    """Where a copy is written before it is linked into place: in the destination folder."""
    return target.with_name(f".{target.name}.migrating")


def blocked(target: Path, dest: Path) -> bool:
    """True when `target` or a folder above it (below `dest`) exists as something that is not a folder."""
    for p in [target, *target.parents]:
        if p == dest.parent:
            break
        if (p.exists() or p.is_symlink()) and (p == target or not p.is_dir()):
            return True
    return False


def plan_move(source: Path, dest: Path) -> tuple[list[tuple[str, Path, Path]], list[tuple[Path, Path]]]:
    """What moving `source` into `dest` would do: ("move"|"same", file, target) steps and the clashes."""
    steps: list[tuple[str, Path, Path]] = []
    clashes: list[tuple[Path, Path]] = []
    for f in sorted(source.rglob("*")):
        if f.is_dir() and not f.is_symlink():
            continue
        target = dest / f.relative_to(source)
        if not blocked(target, dest):
            steps.append(("move", f, target))
        elif f.is_file() and not f.is_symlink() and target.is_file() and f.read_bytes() == target.read_bytes():
            steps.append(("same", f, target))  # left by an interrupted run, or put there by hand
        else:
            clashes.append((f, target))
    return steps, clashes


def fsync_path(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def run_steps(source: Path, steps: list[tuple[str, Path, Path]]) -> int:
    """Carry out planned steps; the number of source files left behind by an I/O error."""
    global errors
    kept = 0
    for kind, f, target in steps:
        rel = f.relative_to(source)
        try:
            partial = partial_of(target)
            if partial.is_file() and not partial.is_symlink():
                partial.unlink()  # an interrupted copy of ours, written beside the destination
            if kind == "move":
                target.parent.mkdir(parents=True, exist_ok=True)
                if f.is_symlink():
                    os.symlink(os.readlink(f), target)
                else:
                    shutil.copy2(f, partial)
                    fsync_path(partial)
                    try:
                        os.link(partial, target)  # fails rather than overwrite
                    finally:
                        partial.unlink()
                fsync_path(target.parent)
            print(f"    {'move' if kind == 'move' else 'same'}     {rel}")
            f.unlink()  # only after the copy is on disk
        except OSError as exc:
            print(f"    ERROR    {rel}: {exc}")
            errors += 1
            kept += 1
    return kept


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true", help="report what would change")
    args = ap.parse_args()
    dry = args.dry_run
    global errors

    if claude_running():
        if not dry:
            print("a claude process is running and may be writing the memory being moved; nothing was changed")
            print("close every Claude session and run this again (activation retries it)", file=sys.stderr)
            raise SystemExit(1)
        print("note: a claude process is running; a real run would stop here")

    # main checkout -> every checkout of its repository; id -> main, by recomputing the old id
    family: dict[Path, list[Path]] = {}
    for checkout in checkout_candidates():
        trees = worktrees(checkout)
        if not trees:
            continue
        main_checkout = Path(os.path.realpath(trees[0]))
        family.setdefault(main_checkout, [])
        for tree in [*trees, checkout]:
            if tree not in family[main_checkout]:
                family[main_checkout].append(tree)
    owners: dict[str, set[Path]] = {}
    for main_checkout in family:
        owners.setdefault(old_repo_id(main_checkout), set()).add(main_checkout)
    computed = set(owners)
    # Fallback for a main checkout outside the roots: the link its worktrees still have.
    for main_checkout, trees in family.items():
        for tree in trees:
            link = tree / ".agents/claude-memory"
            if retired(link, "claude-memory") and link_target(link).name not in computed:
                owners.setdefault(link_target(link).name, set()).add(main_checkout)

    left_with_files: set[str] = set()
    for ident, mains in sorted(owners.items()):
        source = MEMORY_ROOT / ident
        if not source.is_dir() or not has_files(source):
            continue
        print(f"\n{tilde(source)}")
        if len(mains) != 1:
            print(f"  ambiguous: belongs to {', '.join(tilde(m) for m in sorted(mains))}; left alone")
            left_with_files.add(ident)
            continue
        (main_checkout,) = mains
        dest = destination(main_checkout)
        print(f"  -> {tilde(dest)}")
        steps, clashes = plan_move(source, dest)
        if clashes:
            print("  CLASH: nothing of this id is moved; these files differ from what is already there:")
            for f, target in clashes:
                print(f"    {f.relative_to(source)}  (exists at {tilde(target)})")
            left_with_files.add(ident)
            continue
        if dry:
            for kind, f, _ in steps:
                print(f"    {kind}     {f.relative_to(source)}")
        elif run_steps(source, steps):
            left_with_files.add(ident)

    for main_checkout, trees in sorted(family.items()):
        for tree in trees:
            for name in ("tmp", "workflows", "claude-memory"):
                link = tree / ".agents" / name
                if not retired(link, name):
                    continue
                if name == "claude-memory" and link_target(link).name in left_with_files:
                    print(f"\nkeep {tilde(link)}  (its memory is not fully moved)")
                    continue
                print(f"\nremove {tilde(link)}")
                if not dry:
                    try:
                        link.unlink()
                    except OSError as exc:
                        print(f"  ERROR {exc}")
                        errors += 1
            agents = tree / ".agents"
            if agents.is_dir() and not agents.is_symlink() and not any(agents.iterdir()):
                print(f"\nremove {tilde(agents)}  (empty)")
                if not dry:
                    agents.rmdir()

    unclaimed = sorted(
        d.name
        for d in (MEMORY_ROOT.iterdir() if MEMORY_ROOT.is_dir() else [])
        if d.is_dir() and d.name not in owners and has_files(d)
    )
    if unclaimed:
        print("\nmemory no checkout maps to, left in place:")
        for name in unclaimed:
            print(f"  {tilde(MEMORY_ROOT / name)}")
    if TMP_ROOT.is_dir():
        print(f"\nscratch under {tilde(TMP_ROOT)} stays; delete it when you like")
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
