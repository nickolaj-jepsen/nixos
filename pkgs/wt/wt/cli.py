"""Argument parsing and dispatch for the wt command."""

from __future__ import annotations

import argparse
import sys
from typing import Optional

from .commands import (
    cmd_cd,
    cmd_clean,
    cmd_code,
    cmd_create,
    cmd_land,
    cmd_names,
    cmd_remove,
    cmd_smerge,
)
from .guard import cmd_guard
from .status import cmd_list
from .trash import cmd_restore, cmd_trash


def _verb(
    sub: argparse._SubParsersAction,
    name: str,
    help: Optional[str],
    description: str,
    epilog: Optional[str] = None,
) -> argparse.ArgumentParser:
    """One subcommand whose `--help` carries the prose the help index cannot.

    `help=None` keeps the verb out of the index: it is plumbing for hooks and completion.
    """
    extra = {"help": help} if help else {}
    return sub.add_parser(
        name,
        description=description,
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        **extra,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wt",
        description="Manage git worktrees under a shared root.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Worktrees live in <root>/<repo>/<name> (root: WT_WORKTREE_ROOT, default ~/worktrees).\n"
            "\n"
            "A session works and commits inside its worktree; landing is a separate, explicit step:\n"
            "  wt land <name>     rebase onto <default> and fast-forward it; the worktree is kept\n"
            "  wt clean           sweep every worktree whose work already landed\n"
            "  wt remove <name>   discard one worktree, archiving forced work in the trash\n"
            "\n"
            "<default> is the branch origin/HEAD names, else main, else master. Nothing lands and\n"
            "nothing is deleted as a side effect of another command, and `wt land` never commits."
        ),
    )
    sub = parser.add_subparsers(dest="verb", metavar="<verb>")

    listing = _verb(
        sub,
        "list",
        help="Show every worktree with state",
        description="Show every worktree of this repository with the state that decides what can be removed.",
        epilog=(
            "Columns:\n"
            "  STATE     the working tree (clean, dirty, untracked, orphan) plus locked and busy\n"
            "  vs main   commits ahead (+) and behind (-) the default branch\n"
            "  LANDED    whether the branch's changes are already in the default branch, also\n"
            "            when they landed as a squashed or cherry-picked copy\n"
            "  ACTIVITY  how long since the branch last moved\n"
            "\n"
            "--all lists every repository under the root; a target narrows it to one worktree.\n"
            "--json prints {version, root, repos[]}, each repository {name, root, main,\n"
            "defaultBranch, worktrees[]}, with these fields per worktree: name, path, registered,\n"
            "branch, detached, state, ahead, behind, locked, busy, landed, safeToRemove, isMain,\n"
            "idleSeconds."
        ),
    )
    listing.add_argument("--all", action="store_true", help="every repository under the root")
    listing.add_argument("--json", action="store_true", help="machine-readable, for scripts and agents")
    listing.add_argument("target", nargs="?", help="worktree name, path, or . for the current one")
    listing.set_defaults(func=cmd_list)

    create = _verb(
        sub,
        "create",
        help="Create a worktree on a new branch",
        description="Create a worktree on a new branch and print its path.",
        epilog=(
            "The base defaults to origin/<default> (fetched when the last fetch is over a day old),\n"
            "else the local default branch. The directory is <root>/<repo>/<name>, with slashes in\n"
            "the name turned into dashes. Gitignored paths listed in the primary checkout's\n"
            ".worktreeinclude are copied in.\n"
            "\n"
            "`git worktree add` is allowed only inside the root: the agent hooks refuse it\n"
            "anywhere else, so create worktrees through this verb."
        ),
    )
    create.add_argument("name")
    create.add_argument("base", nargs="?")
    create.set_defaults(func=cmd_create)

    cd = _verb(
        sub,
        "cd",
        help="Print a worktree path (fzf picker if no name)",
        description="Print a worktree's path, or the primary checkout's with --main.",
        epilog=(
            "Without a target an fzf picker lists the worktrees, so it needs a terminal.\n"
            "The point is `cd $(wt cd <name>)`, which moves a shell without moving an agent's session."
        ),
    )
    cd.add_argument("--main", action="store_true", help="the primary checkout")
    cd.add_argument("target", nargs="?")
    cd.set_defaults(func=cmd_cd)

    land = _verb(
        sub,
        "land",
        help="Rebase onto the default branch and fast-forward it",
        description="Rebase a worktree onto the default branch and fast-forward the default branch onto it.",
        epilog=(
            "The worktree and its branch are kept, so the session working there carries on; the\n"
            "commits are now in the default branch, `wt list` marks it LANDED, and `wt clean`\n"
            "sweeps it later. Nothing here commits: commit inside the worktree first.\n"
            "\n"
            "Where the default branch is checked out (usually the primary checkout), fast-forwarding\n"
            "writes the landed files into that working tree. Uncommitted changes there are left\n"
            "alone; landing refuses only when the branch also changes those paths. When a live\n"
            "process works in that checkout, land names it and how many paths changed, so the\n"
            "session there can be told. When no checkout has the default branch, only the ref moves.\n"
            "\n"
            "A conflict pauses the rebase inside the worktree: resolve it there, then\n"
            "`wt land --continue <name>`, or `wt land --abort <name>` to put the branch back."
        ),
    )
    land.add_argument("--dry-run", action="store_true", help="show what would be done")
    land.add_argument(
        "--abort-on-conflict", action="store_true", help="abort the rebase on conflict instead of pausing"
    )
    land.add_argument("--continue", dest="continue_rebase", action="store_true", help="finish a paused rebase, then land")
    land.add_argument("--abort", action="store_true", help="abort a paused rebase")
    land.add_argument("target", nargs="?", help="worktree name, path, or . for the current one")
    land.set_defaults(func=cmd_land)

    clean = _verb(
        sub,
        "clean",
        help="Remove worktrees with nothing left to lose",
        description="Remove every worktree whose work is already in the default branch.",
        epilog=(
            "A worktree qualifies only when it is clean, its branch is contained in the default\n"
            "branch, no live process other than this one has its cwd inside, and it is not locked.\n"
            "The worktree holding the caller's cwd is skipped, so run it from the primary checkout.\n"
            "The primary checkout itself is never touched, nor is a worktree on the default branch.\n"
            "Orphan directories git no longer registers are removed when empty.\n"
            "\n"
            "Every worktree it keeps is named with the reason: uncommitted changes, commits not in\n"
            "the default branch, another process inside, locked, or on the default branch. So a\n"
            "sweep that removes nothing still says what stands in the way.\n"
            "\n"
            "This is how a landed worktree goes away, since `wt land` keeps it: `wt list` shows\n"
            "LANDED yes, `wt clean` removes it."
        ),
    )
    clean.add_argument("--dry-run", action="store_true", help="show what would be removed, and why the rest stay")
    clean.set_defaults(func=cmd_clean)

    remove = _verb(
        sub,
        "remove",
        help="Remove one worktree, archiving forced work",
        description="Remove one worktree and its branch, archiving work that would otherwise be lost.",
        epilog=(
            "Refuses when the worktree has uncommitted changes or carries work the default branch\n"
            "does not have, and refuses while a live process has its cwd inside it. --force archives\n"
            "the dirty or unlanded work into the trash first, and --ignore-in-use removes it even\n"
            "with a process inside; an agent asks before passing either. `wt restore <id>` brings\n"
            "archived work back; `wt trash purge` drops it for good."
        ),
    )
    remove.add_argument("--dry-run", action="store_true", help="show what would be removed")
    remove.add_argument("--force", action="store_true", help="archive dirty or unlanded work and remove anyway")
    remove.add_argument("--ignore-in-use", action="store_true", help="remove despite a live process inside")
    remove.add_argument("target", help="worktree name, path, or . for the current one")
    remove.set_defaults(func=cmd_remove)

    trash = _verb(
        sub,
        "trash",
        help="List or purge archived work",
        description="List the work archived by `wt remove --force`, or purge it.",
        epilog=(
            "Lists this repository's entries; --all covers every repository, and purges all of them.\n"
            "An entry holds the tracked diff and the untracked files of the worktree it came from."
        ),
    )
    trash.add_argument("action", nargs="?", choices=["list", "purge"], default="list")
    trash.add_argument("id", nargs="?", help="trash entry to purge")
    trash.add_argument("--all", action="store_true", help="every repository / every entry")
    trash.add_argument("--json", action="store_true")
    trash.set_defaults(func=cmd_trash)

    restore = _verb(
        sub,
        "restore",
        help="Restore archived work",
        description="Restore an archived worktree as a new worktree and branch.",
        epilog=(
            "The entry keeps its name and branch when both are free; --name <new-name> restores it\n"
            "under a different one. The recorded tracked diff is reapplied onto the commit it\n"
            "records, and archived untracked files are unpacked into place."
        ),
    )
    restore.add_argument("id")
    restore.add_argument("--name", help="new worktree and branch name")
    restore.set_defaults(func=cmd_restore)

    smerge = _verb(
        sub,
        "smerge",
        help="Open a worktree in Sublime Merge",
        description="Open a worktree in Sublime Merge.",
    )
    smerge.add_argument("target", nargs="?")
    smerge.set_defaults(func=cmd_smerge)

    code = _verb(
        sub,
        "code",
        help="Open a worktree in VS Code",
        description="Open a worktree in VS Code, in its own window.",
    )
    code.add_argument("target", nargs="?")
    code.set_defaults(func=cmd_code)

    names = _verb(
        sub,
        "names",
        help=None,
        description="Print every worktree name, one per line, for completion and pickers.",
    )
    names.set_defaults(func=cmd_names)

    guard = _verb(
        sub,
        "guard",
        help=None,
        description=(
            "Refuse a `git worktree add` or `git worktree move` that would land outside the shared root,\n"
            "and a `git switch` or branch `git checkout` inside a worktree under it."
        ),
        epilog=(
            "The agent hooks (pi, Claude Code, opencode) run this on each shell command that\n"
            "mentions worktree, switch or checkout. It prints why it refused and exits 1, or prints\n"
            "nothing and exits 0."
        ),
    )
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
