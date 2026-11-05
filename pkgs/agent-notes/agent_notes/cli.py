"""`agent-notes`: where a checkout's notes live, and the links that show them beside the code."""

import argparse
import os
import sys
from pathlib import Path

from . import layout, links, migrate


def _path(value):
    return os.path.realpath(value or os.getcwd())


def cmd_id(args):
    print(layout.repo_id(_path(args.path)))
    return 0


def cmd_root(args):
    root = _path(args.path)
    if args.ensure:
        links.ensure(layout.worktree_root(root) or root, create_store=True, report=_warn)
    directory = layout.store_root() / layout.repo_id(root)
    if args.ensure:
        directory.mkdir(parents=True, exist_ok=True)
    print(directory)
    return 0


def cmd_tmp(args):
    root = _path(args.path)
    directory = layout.tmp_root() / layout.repo_id(root) / str(args.pid or os.getppid())
    directory.mkdir(parents=True, exist_ok=True)
    print(directory)
    return 0


def cmd_init(args):
    root = layout.worktree_root(_path(args.path))
    if root is None:
        return 0
    problems = links.ensure(root, create_store=args.ensure_store, report=_warn)
    for problem in problems:
        _warn(problem)
    return 1 if problems and args.strict else 0


def cmd_status(args):
    root = _path(args.path)
    print(f"id      {layout.repo_id(root)}")
    print(f"store   {layout.store_root() / layout.repo_id(root)}")
    print(f"tmp     {layout.tmp_root() / layout.repo_id(root)}")
    checkout = layout.worktree_root(root)
    if checkout:
        for name, (path, target) in layout.links(checkout).items():
            if path.is_symlink():
                state = "ok" if os.path.realpath(path) == os.path.realpath(target) else f"-> {os.readlink(path)}"
            elif path.exists():
                state = "real"
            else:
                state = "missing"
            print(f"{name:7} {path}  {state}")
    return 0


def cmd_migrate(args):
    mappings = {}
    for pair in args.map or []:
        old, _, new = pair.partition("=")
        if not old or not new:
            sys.exit(f"--map wants OLD=ID, not {pair!r}")
        mappings[old] = new
    result = migrate.plan(mappings)
    migrate.report(result, keep_unclaimed=args.keep_unclaimed)
    if not args.apply:
        print("\nDry run. Rerun with --apply once every project above maps where you want it.")
        return 0
    summary = migrate.apply(result, keep_unclaimed=args.keep_unclaimed, say=_warn)
    print(f"\nApplied: {summary['moves']} files moved, {summary['orphans']} orphaned, "
          f"{summary['deleted']} unclaimed deleted, {summary['kept']} kept, "
          f"{summary['freed']} bytes freed, {summary['rewritten']} files rewritten.")
    return 0


def _warn(message):
    print(message, file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="agent-notes",
        description="Where a checkout's agent notes live: the store, its scratch, and the links into it.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    for name, func, help in [
        ("id", cmd_id, "the store directory name for a checkout"),
        ("root", cmd_root, "the store directory a checkout's notes live in"),
        ("tmp", cmd_tmp, "the scratch directory for a session"),
    ]:
        command = sub.add_parser(name, help=help)
        command.add_argument("--path", help="a directory in the checkout (default: cwd)")
        command.set_defaults(func=func)
        if name == "root":
            command.add_argument("--ensure", action="store_true", help="create the store and repair the links")
        if name == "tmp":
            command.add_argument("pid", nargs="?", type=int, help="the session's pid (default: the caller's parent)")

    init = sub.add_parser("init", help="create or repair .agents/{store,tmp} for a checkout; quiet, never fails a git hook")
    init.add_argument("--path", help="a directory in the checkout (default: cwd)")
    init.add_argument("--ensure-store", action="store_true", help="also create the store directory")
    init.add_argument("--strict", action="store_true", help="exit 1 when a path was left alone")
    # Git hands post-checkout its old head, new head and flag; they matter to nobody here.
    init.add_argument("git_args", nargs="*", help=argparse.SUPPRESS)
    init.set_defaults(func=cmd_init)

    status = sub.add_parser("status", help="what this checkout resolves to, and the state of its links")
    status.add_argument("--path", help="a directory in the checkout (default: cwd)")
    status.set_defaults(func=cmd_status)

    moving = sub.add_parser("migrate", help="move notes from the old per-project layout into the store")
    moving.add_argument("--apply", action="store_true", help="perform it; without this it is a dry run")
    moving.add_argument("--map", action="extend", nargs="+", metavar="OLD=ID", help="map an old project name to a store id")
    moving.add_argument("--keep-unclaimed", action="store_true",
                        help="keep files no note names under _orphaned instead of deleting them")
    moving.set_defaults(func=cmd_migrate)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
