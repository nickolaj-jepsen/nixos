"""Argument parsing and dispatch for the wt command."""

from __future__ import annotations

import argparse
import sys
from typing import Optional

from .commands import (
    cmd_apply,
    cmd_cd,
    cmd_clean,
    cmd_code,
    cmd_create,
    cmd_diff,
    cmd_migrate,
    cmd_names,
    cmd_remove,
    cmd_smerge,
    cmd_sync,
)
from .guard import cmd_guard
from .status import cmd_list, cmd_status
from .trash import cmd_restore, cmd_trash


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wt",
        description="Manage git worktrees under a shared root.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Worktrees live in <root>/<repo>/<name> (root: WT_WORKTREE_ROOT, default ~/worktrees).\n"
            "`clean` removes finished worktrees; `remove` targets one and archives forced work in the trash."
        ),
    )
    sub = parser.add_subparsers(dest="verb")

    listing = sub.add_parser("list", help="Show every worktree with state")
    listing.add_argument("--all", action="store_true", help="every repository under the root")
    listing.set_defaults(func=cmd_list)

    status = sub.add_parser("status", help="Machine-readable JSON status")
    status.add_argument("--all", action="store_true", help="every repository under the root")
    status.add_argument("target", nargs="?", help="worktree name or . for the current one")
    status.set_defaults(func=cmd_status)

    create = sub.add_parser("create", help="Create a worktree on a new branch")
    create.add_argument("name")
    create.add_argument("base", nargs="?")
    create.set_defaults(func=cmd_create)

    cd = sub.add_parser("cd", help="Print a worktree path (fzf picker if no name)")
    cd.add_argument("--main", action="store_true", help="the primary checkout")
    cd.add_argument("target", nargs="?")
    cd.set_defaults(func=cmd_cd)

    clean = sub.add_parser("clean", help="Remove worktrees with nothing left to lose")
    clean.add_argument("--dry-run", action="store_true")
    clean.set_defaults(func=cmd_clean)

    remove = sub.add_parser("remove", help="Remove one worktree, archiving forced work")
    remove.add_argument("--dry-run", action="store_true")
    remove.add_argument("--force", action="store_true", help="archive dirty or unlanded work and remove anyway")
    remove.add_argument("--ignore-in-use", action="store_true", help="remove despite a live process inside")
    remove.add_argument("target")
    remove.set_defaults(func=cmd_remove)

    trash = sub.add_parser("trash", help="List or purge archived work")
    trash.add_argument("action", nargs="?", choices=["list", "purge"], default="list")
    trash.add_argument("id", nargs="?", help="trash entry to purge")
    trash.add_argument("--all", action="store_true", help="every repository / every entry")
    trash.add_argument("--json", action="store_true")
    trash.set_defaults(func=cmd_trash)

    restore = sub.add_parser("restore", help="Restore archived work")
    restore.add_argument("id")
    restore.add_argument("--name", help="new worktree and branch name")
    restore.set_defaults(func=cmd_restore)

    apply = sub.add_parser("apply", help="Rebase, remove the worktree, and fast-forward default")
    apply.add_argument("--dry-run", action="store_true")
    apply.add_argument("--abort-on-conflict", action="store_true")
    apply.add_argument("--continue", dest="continue_rebase", action="store_true")
    apply.add_argument("--abort", action="store_true")
    apply.add_argument("target", nargs="?")
    apply.set_defaults(func=cmd_apply)

    sync = sub.add_parser("sync", help="Rebase a worktree onto local default")
    sync.add_argument("--dry-run", action="store_true")
    sync.add_argument("--abort-on-conflict", action="store_true")
    sync.add_argument("--continue", dest="continue_rebase", action="store_true")
    sync.add_argument("--abort", action="store_true")
    sync.add_argument("target", nargs="?")
    sync.set_defaults(func=cmd_sync)

    diff = sub.add_parser("diff", help="Review a worktree diff")
    diff.add_argument("--stat", action="store_true")
    diff.add_argument("--name-only", action="store_true")
    diff.add_argument("--patch", action="store_true")
    diff.add_argument("target", nargs="?")
    diff.set_defaults(func=cmd_diff)

    smerge = sub.add_parser("smerge", help="Open a worktree in Sublime Merge")
    smerge.add_argument("target", nargs="?")
    smerge.set_defaults(func=cmd_smerge)

    code = sub.add_parser("code", help="Open a worktree in VS Code")
    code.add_argument("target", nargs="?")
    code.set_defaults(func=cmd_code)

    migrate = sub.add_parser("migrate", help="Move worktrees outside the root into it")
    migrate.add_argument("--dry-run", action="store_true")
    migrate.set_defaults(func=cmd_migrate)

    names = sub.add_parser("names", help="Print every worktree name")
    names.set_defaults(func=cmd_names)

    guard = sub.add_parser("guard", help="Refuse git worktree add/move outside the root")
    guard.add_argument("command")
    guard.set_defaults(func=cmd_guard)

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "verb", None):
        parser.print_usage(sys.stderr)
        return 1
    try:
        args.func(args)
    except SystemExit as exc:
        return int(exc.code or 0)
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
