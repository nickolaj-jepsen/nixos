"""Ageing out session scratch that a plain recursive delete cannot.

Scratch under `<state>/agents/tmp/<repo>/` is disposable: anything a session
leaves untouched for three days goes. `systemd-tmpfiles` cannot do it on its own.
It stops at the first directory it may not open or write, and then leaves the
rest of that session alone: Go's module cache is `r-xr-xr-x`, so unlinking a
file inside it fails, and a test bed can leave a `d---------` directory owned by
another uid, which it cannot even enter. Both are logged and ignored, so a
multi-gigabyte test bed survives its age forever (docs/notes.md).

This walks the same layout and deletes what it can: read-only directories are
made writable first, an empty unreadable one is removed without entering it, and
whatever is left — a directory owned by someone else and not empty — is reported
rather than retried silently every day.
"""

import os
import stat
import time
from pathlib import Path

from .layout import tmp_root

DAY = 24 * 60 * 60
UNITS = {"s": 1, "m": 60, "h": 60 * 60, "d": DAY}
THREE_DAYS = 3 * DAY


def parse_age(text):
    """`3d`, `12h`, `90m`, `45s`; a bare number is days, as the tmpfiles age field reads."""
    value = str(text).strip().lower()
    if value and value[-1] in UNITS:
        number, unit = value[:-1], value[-1]
    else:
        number, unit = value, "d"
    try:
        age = float(number) * UNITS[unit]
    except ValueError:
        raise ValueError(f"max age wants 90m, 12h or 3d, not {text!r}") from None
    if age <= 0:
        raise ValueError(f"max age must be positive, not {text!r}")
    return age


def human(count):
    """Bytes as a person reads them: `512B`, `12.3G`."""
    for unit in ("B", "K", "M", "G"):
        if count < 1024:
            return f"{count:.0f}{unit}" if unit == "B" else f"{count:.1f}{unit}"
        count /= 1024
    return f"{count:.1f}T"


def entries(root=None, max_age=THREE_DAYS, now=None):
    """What outlived `max_age`: every entry under each repository directory, never the repositories.

    The repository level has to stay, or a checkout's `.agents/tmp` link dangles.
    Age is the entry's own mtime, as in a tmpfiles rule, so a session that is
    still writing keeps its directory alive.
    """
    now = time.time() if now is None else now
    directory = Path(root or tmp_root())
    if not directory.is_dir():
        return
    for project in sorted(directory.iterdir()):
        if project.is_symlink() or not project.is_dir():
            continue
        try:
            children = sorted(project.iterdir())
        except OSError:
            continue
        for entry in children:
            try:
                mtime = entry.lstat().st_mtime
            except (FileNotFoundError, PermissionError):
                continue
            if now - mtime >= max_age:
                yield entry


def size(path):
    """Apparent bytes under `path`, counting what it may not enter as nothing."""
    try:
        info = path.lstat()
    except OSError:
        return 0
    if not stat.S_ISDIR(info.st_mode):
        return info.st_size
    total = info.st_size
    try:
        names = os.listdir(path)
    except OSError:
        return total
    for name in names:
        total += size(path / name)
    return total


def remove(path):
    """Delete `path` whatever its mode. Returns the paths something else owns."""
    try:
        info = path.lstat()
    except OSError:
        return []
    if not stat.S_ISDIR(info.st_mode):
        try:
            path.unlink()
        except FileNotFoundError:
            return []
        except PermissionError:
            return [path]
        return []
    # A directory is emptied and then removed, and only its parent has to be
    # writable for that, so a mode it will not let us read is not fatal when empty.
    try:
        path.chmod(0o700)
    except OSError:
        pass
    try:
        names = os.listdir(path)
    except PermissionError:
        try:
            path.rmdir()
        except OSError:
            return [path]
        return []
    blocked = []
    for name in names:
        blocked += remove(path / name)
    try:
        path.rmdir()
    except OSError:
        blocked.append(path)
    return blocked


def reap(root=None, max_age=THREE_DAYS, apply=False, now=None, say=None):
    """Age out the stale entries, deleting them when `apply`. Returns the summary."""
    say = say or (lambda _message: None)
    summary = {"stale": 0, "removed": 0, "bytes": 0, "blocked": []}
    for entry in list(entries(root, max_age=max_age, now=now)):
        summary["stale"] += 1
        freed = size(entry)
        if not apply:
            summary["bytes"] += freed
            say(f"would reap {entry} ({human(freed)})")
            continue
        blocked = remove(entry)
        if blocked:
            summary["blocked"] += blocked
            say(f"could not reap {entry} ({human(freed)}): {len(blocked)} paths are not yours")
            continue
        summary["removed"] += 1
        summary["bytes"] += freed
        say(f"reaped {entry} ({human(freed)})")
    return summary
