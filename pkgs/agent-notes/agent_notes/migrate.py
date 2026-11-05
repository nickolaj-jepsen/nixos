"""Moving the old per-project notes into the per-checkout store.

The old layout put every project under the data root by bare name. The store
keys a directory by checkout instead, so each old project is mapped to an id,
its Markdown follows, and the artifacts its notes name go to that topic's
`files/`. Anything left over is reported and, on `apply`, deleted: it is the
part nothing refers to.

References are rewritten after the move: absolute and home-relative paths of
every file that moved, in the notes the move left behind and in the agents'
memory files.
"""

import os
import re
import shutil
import sys
from pathlib import Path

from .layout import GLOBAL, ORPHANED, RESERVED, data_root, main_worktree, orphan_root, repo_id, store_root

KINDS = {"plans", "research", "ideas", "findings", "onboard", "reports", "scripts"}
TEXT_MAX = 4 << 20
MEMORY_GLOBS = [
    ".pi/agent/memory/**/*.md",
    ".pi/agent/memoria/MEMORY.md",
    ".claude/projects/*/memory/*.md",
    ".claude-work/projects/*/memory/*.md",
]


def _home_forms(root):
    """The spellings of `root` that notes use, longest first."""
    forms = [str(root)]
    home = str(Path.home())
    if str(root).startswith(home + "/"):
        relative = str(root)[len(home) + 1:]
        forms += [f"~/{relative}", f"$HOME/{relative}"]
    return forms


def _path_pattern(root):
    """Matching any spelling of a path under the data root, as an agent wrote it in prose."""
    forms = "|".join(re.escape(form) for form in _home_forms(root))
    return re.compile(rf"(?:{forms})/[^\s`'\"()\[\]{{}}<>,;]*")


def _is_text(path):
    try:
        if path.stat().st_size > TEXT_MAX:
            return False
        with open(path, "rb") as handle:
            return b"\0" not in handle.read(8192)
    except OSError:
        return False


def _files(root):
    """Every file under `root`, symlinks not followed.

    A symlinked directory is yielded as the link it is: descending would copy the
    target's contents into the store, and skipping it would leave the link behind
    as an empty shell once its siblings moved.
    """
    root = Path(root)
    if root.is_file() or root.is_symlink():
        yield root
        return
    for dirpath, dirs, files in os.walk(root):
        links = [d for d in dirs if os.path.islink(os.path.join(dirpath, d))]
        dirs[:] = [d for d in dirs if d != ".git" and d not in links]
        for name in [*files, *links]:
            yield Path(dirpath) / name


def _topic(project, relative):
    """`plans/<slug>` or `research/<topic>` for a path inside one, else None."""
    parts = relative.parts
    if len(parts) >= 2 and parts[0] in {"plans", "research"}:
        return Path(parts[0]) / parts[1]
    if parts and parts[0] == "onboard":
        return Path("onboard")
    return None


def _markdown(project):
    """Every note and history file under a project: Markdown outside `files/`."""
    for path in _files(project):
        if path.suffix != ".md":
            continue
        relative = path.relative_to(project)
        if any(part == "files" or part.startswith(".") for part in relative.parts[:-1]):
            continue
        yield path


def _claimed_paths(projects):
    """Absolute old paths that some note names, including the directories above them.

    A note that names a directory claims everything below it; that is how a spike
    directory's blobs are kept without every file being listed in prose.
    """
    claimed = set()
    pattern = _path_pattern(data_root())
    home = str(Path.home())
    for project in projects:
        for note in _markdown(project):
            if not _is_text(note):
                continue
            try:
                text = note.read_text(errors="replace")
            except OSError:
                continue
            for match in pattern.finditer(text):
                path = match.group(0).replace("$HOME", home)
                path = os.path.expanduser(path)
                while path and path[-1] in ".,;:)]":
                    path = path[:-1]
                if os.path.isabs(path):
                    claimed.add(os.path.normpath(path))
    return claimed


def _is_claimed(path, claimed):
    """Whether `path` or one of its ancestors is named by a note."""
    path = os.path.normpath(str(path))
    while True:
        if path in claimed:
            return True
        parent = os.path.dirname(path)
        if parent == path:
            return False
        path = parent


def _resolve(old, mappings, repos):
    """The store id for an old project name, or None when nothing decides it."""
    if old in mappings:
        return mappings[old]
    if old in RESERVED:
        return old
    return repos.get(old)


def discover(root=None):
    """Basename → id for the checkouts a mapping may name, so a project finds itself.

    Worktrees are asked where their main checkout is, because it may sit below a
    monorepo (`~/dev/devenv-tilt/projects/<name>`) or anywhere else, and a project
    only maps by the name of that main checkout.
    """
    found = {}

    def add(path):
        if path and (Path(path) / ".git").exists():
            found.setdefault(Path(path).name, repo_id(path))

    for parent in (Path.home() / "dev", Path.home()):
        if not parent.is_dir():
            continue
        for child in parent.iterdir():
            if child.name.startswith(".") or not child.is_dir():
                continue
            add(child)
    worktrees = Path.home() / "worktrees"
    for tree in sorted(worktrees.glob("*/*")) if worktrees.is_dir() else []:
        if (tree / ".git").exists():
            add(main_worktree(tree))
    if root:
        found.update(root)
    return found


def plan(mappings=None, repos=None):
    """What the migration would do, without touching anything."""
    mappings = mappings or {}
    repos = discover() if repos is None else repos
    root = data_root()
    store = store_root()
    projects, unresolved, moves, files = [], [], [], []
    for entry in sorted(root.iterdir()) if root.is_dir() else []:
        if entry.name in {"store", ORPHANED} or entry.name.startswith("."):
            continue
        if not entry.is_dir() or entry.is_symlink():
            unresolved.append((entry.name, [entry]))
            continue
        target = _resolve(entry.name, mappings, repos)
        if target:
            projects.append((entry, target))
        else:
            unresolved.append((entry.name, list(_files(entry))))
    # A project that mapped nowhere when it was moved may map now that its checkout
    # is known; the files nobody claimed stay parked under its `unclaimed/`.
    for entry in sorted(orphan_root().iterdir()) if orphan_root().is_dir() else []:
        if not entry.is_dir() or entry.is_symlink():
            continue
        target = _resolve(entry.name, mappings, repos)
        if target:
            projects.append((entry, target))
    claimed = _claimed_paths([entry for entry, _ in projects])
    for entry, target in projects:
        for path in _files(entry):
            relative = path.relative_to(entry)
            # What an orphaned project left parked stays parked.
            if relative.parts[0] == "unclaimed":
                continue
            if path.suffix == ".md" and "files" not in relative.parts[:-1]:
                moves.append((path, store / target / relative))
                continue
            if _is_claimed(path, claimed):
                topic = _topic(entry, relative)
                destination = store / target / (topic or Path("")) / "files" / (
                    relative.relative_to(topic) if topic else relative)
                moves.append((path, destination))
            else:
                files.append((entry.name, path, relative))
    orphans = []
    for name, paths in unresolved:
        for path in paths:
            if path.suffix == ".md":
                orphans.append((path, orphan_root() / name / path.relative_to(root / name)))
            else:
                files.append((name, path, path.relative_to(root / name)))
    return {"root": root, "store": store, "projects": projects, "moves": moves,
            "orphans": orphans, "unclaimed": files}


def _bytes(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def _relative_to_data(path, root):
    try:
        return Path(path).relative_to(root)
    except ValueError:
        return None


def _rewrite(path, replacements):
    """Rewrite every spelling of a moved path in one text file; True when it changed."""
    if not _is_text(path):
        return False
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return False
    new = text
    for spelling, target in replacements:
        if spelling in new:
            new = new.replace(spelling, target)
    if new == text:
        return False
    path.write_text(new)
    return True


def _replacements(source, destination, root):
    """Each spelling of a moved path, and the spelling that path now needs."""
    relative = source.relative_to(root)
    home = str(Path.home())
    target = str(destination)
    home_target = "~/" + target[len(home) + 1:] if target.startswith(home + "/") else None
    pairs = []
    for form in _home_forms(root):
        spelling = f"{form}/{relative}"
        if form.startswith("~") and home_target:
            pairs.append((spelling, f"{home_target}"))
        elif form.startswith("$HOME") and home_target:
            pairs.append((spelling, f"$HOME/{target[len(home) + 1:]}"))
        else:
            pairs.append((spelling, target))
    return pairs


def _collisions(result):
    """Destinations two sources claim, which would silently overwrite one of them."""
    seen, clashes = {}, []
    for source, destination in result["moves"] + result["orphans"]:
        if destination in seen:
            clashes.append((seen[destination], source, destination))
        seen[destination] = source
    return clashes


def apply(result, keep_unclaimed=False, say=print):
    """Perform the plan: map, orphan, move claimed artifacts, delete the rest, rewrite paths."""
    root, store = result["root"], result["store"]
    clashes = _collisions(result)
    if clashes:
        lines = [f"refusing to apply: two sources want {destination}:\n    {first}\n    {second}"
                 for first, second, destination in clashes]
        sys.exit("\n".join(lines))
    for destination in [destination for _, destination in result["moves"] + result["orphans"]]:
        if destination.exists():
            sys.exit(f"refusing to apply: {destination} already exists")
    store.mkdir(parents=True, exist_ok=True)
    replacements = []
    for source, destination in result["moves"]:
        replacements += _replacements(source, destination, root)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source), str(destination))
    moved_orphans = 0
    for source, destination in result["orphans"]:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source), str(destination))
        moved_orphans += 1
    freed = 0
    for name, path, relative in result["unclaimed"]:
        if keep_unclaimed:
            destination = orphan_root() / name / "unclaimed" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(path), str(destination))
            continue
        freed += _bytes(path)
        try:
            path.unlink()
        except OSError as error:
            say(f"  failed to remove {path}: {error}")
    # Longest first, so a path is rewritten before the directory that contains it.
    replacements.sort(key=lambda pair: -len(pair[0]))
    rewritten = 0
    for tree in (store, orphan_root()):
        for path in _files(tree) if tree.is_dir() else []:
            if path.suffix in {".md", ".txt", ".json", ".yaml", ".yml"}:
                rewritten += _rewrite(path, replacements)
    memory = sorted({path for pattern in MEMORY_GLOBS for path in Path.home().glob(pattern) if path.is_file()})
    for path in memory:
        rewritten += _rewrite(path, replacements)
    for entry in sorted(root.iterdir()):
        if entry.is_dir() and not entry.is_symlink():
            for dirpath, dirs, files in os.walk(entry, topdown=False):
                if not files and not os.listdir(dirpath):
                    os.rmdir(dirpath)
    return {"moves": len(result["moves"]), "orphans": moved_orphans,
            "deleted": len(result["unclaimed"]) if not keep_unclaimed else 0,
            "kept": len(result["unclaimed"]) if keep_unclaimed else 0,
            "freed": freed, "rewritten": rewritten}


def _left_in_place(project, result):
    """Files and links the plan neither moves nor classifies: a nested `.git`, or a dot dir."""
    planned = {source for source, _ in result["moves"] + result["orphans"]}
    planned |= {path for _, path, _relative in result["unclaimed"]}
    for dirpath, dirs, files in os.walk(project):
        links = [d for d in dirs if os.path.islink(os.path.join(dirpath, d))]
        for name in [*files, *links]:
            path = Path(dirpath) / name
            if path not in planned:
                yield path
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(dirpath, d))]


def report(result, out=sys.stdout, keep_unclaimed=False):
    """The dry run: every move, every orphan, every deletion, with sizes."""
    out.write(f"# store: {result['store']}\n")
    for entry, target in result["projects"]:
        out.write(f"\n## {entry.name} -> store/{target}\n")
        for source, destination in result["moves"]:
            if source.is_relative_to(entry):
                out.write(f"  {source.relative_to(result['root'])}  ->  {destination.relative_to(result['store'])}\n")
    orphans = [source for source, _ in result["orphans"]]
    if orphans:
        out.write(f"\n## unresolved, to {ORPHANED}/ ({len(orphans)} files, "
                  f"{sum(_bytes(p) for p in orphans)} bytes)\n")
        for source in orphans:
            out.write(f"  {source}\n")
    left = sorted(str(source) for project, _ in result["projects"]
                  for source in _left_in_place(project, result))
    if left:
        out.write(f"\n## left in place ({len(left)}: nested `.git` directories and dot dirs)\n")
        for source in left:
            out.write(f"  {source}\n")
    unclaimed = result["unclaimed"]
    action = "keep under _orphaned" if keep_unclaimed else "delete"
    out.write(f"\n## unclaimed, to {action} ({len(unclaimed)} files, "
              f"{sum(_bytes(path) for _, path, _relative in unclaimed)} bytes)\n")
    for name, _path, relative in unclaimed:
        out.write(f"  {name}/{relative}\n")
