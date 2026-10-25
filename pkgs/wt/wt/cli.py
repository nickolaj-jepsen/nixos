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


def _verb(
    sub: argparse._SubParsersAction,
    name: str,
    help: str,
    description: str,
    epilog: Optional[str] = None,
) -> argparse.ArgumentParser:
    """One subcommand whose `--help` carries the prose the help index cannot."""
    return sub.add_parser(
        name,
        help=help,
        description=description,
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wt",
        description="Manage git worktrees under a shared root.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Worktrees live in <root>/<repo>/<name> (root: WT_WORKTREE_ROOT, default ~/worktrees).\n"
            "\n"
            "A session works and commits inside its worktree, then lands those commits:\n"
            "  wt apply <name>            rebase onto <default> and fast-forward it; worktree kept\n"
            "  wt apply --remove <name>   the same, then delete the worktree and its branch\n"
            "  wt clean                   sweep every worktree whose work already landed\n"
            "  wt sync <name>             catch up with <default> without landing anything\n"
            "  wt remove <name>           discard a worktree, archiving forced work in the trash\n"
            "\n"
            "<default> is the branch origin/HEAD names, else main, else master. No verb removes a\n"
            "worktree on its own, and `wt apply` never commits: landing is always something a\n"
            "person or an agent asked for."
        ),
    )
    sub = parser.add_subparsers(dest="verb")

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
            "--all lists every repository under the root instead."
        ),
    )
    listing.add_argument("--all", action="store_true", help="every repository under the root")
    listing.set_defaults(func=cmd_list)

    status = _verb(
        sub,
        "status",
        help="Machine-readable JSON status",
        description="Print the state `wt list` shows as JSON, for scripts and agents.",
        epilog=(
            "The document is {version, root, repos[]} and each repository is\n"
            "{name, root, main, defaultBranch, worktrees[]}, with these fields per worktree:\n"
            "name, path, registered, branch, detached, state, ahead, behind, locked, busy,\n"
            "landed, safeToRemove, isMain, idleSeconds.\n"
            "\n"
            "--all covers every repository under the root; a target narrows it to one worktree."
        ),
    )
    status.add_argument("--all", action="store_true", help="every repository under the root")
    status.add_argument("target", nargs="?", help="worktree name or . for the current one")
    status.set_defaults(func=cmd_status)

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
            "`git worktree add` is allowed only inside the root: the agent hooks and `wt guard`\n"
            "refuse it anywhere else, so create worktrees through this verb."
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

    clean = _verb(
        sub,
        "clean",
        help="Remove worktrees with nothing left to lose",
        description="Remove every worktree whose work is already in the default branch.",
        epilog=(
            "A worktree qualifies only when it is clean, its branch is contained in the default\n"
            "branch, no live process has its cwd inside, and it is not locked. The primary checkout\n"
            "is never touched, nor is a worktree on the default branch. Orphan directories git no\n"
            "longer registers are removed when empty.\n"
            "\n"
            "This is how a landed worktree goes away, since `wt apply` keeps it: `wt list` shows\n"
            "LANDED yes, `wt clean` removes it."
        ),
    )
    clean.add_argument("--dry-run", action="store_true", help="show what would be removed")
    clean.set_defaults(func=cmd_clean)

    remove = _verb(
        sub,
        "remove",
        help="Remove one worktree, archiving forced work",
        description="Remove one worktree, archiving work that would otherwise be lost.",
        epilog=(
            "Refuses when the worktree has uncommitted changes or carries work the default branch\n"
            "does not have, and refuses while a live process has its cwd inside it. --force archives\n"
            "the dirty or unlanded work into the trash first, and --ignore-in-use removes it even\n"
            "with a process inside. `wt restore <id>` brings archived work back; `wt trash purge`\n"
            "drops it for good."
        ),
    )
    remove.add_argument("--dry-run", action="store_true", help="show what would be removed")
    remove.add_argument("--force", action="store_true", help="archive dirty or unlanded work and remove anyway")
    remove.add_argument("--ignore-in-use", action="store_true", help="remove despite a live process inside")
    remove.add_argument("target", help="worktree name, or . for the current one")
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

    apply = _verb(
        sub,
        "apply",
        help="Land a branch; keep the worktree or remove it",
        description=(
            "Rebase a worktree onto the default branch and fast-forward the default branch onto it."
        ),
        epilog=(
            "The worktree and its branch are kept, so the session working there carries on; the\n"
            "commits (or their squash-merged copies) are now in the default branch, and `wt list`\n"
            "marks it LANDED. --remove finishes it instead: fast-forward, then delete the worktree\n"
            "and its branch, which it refuses to do from inside that directory.\n"
            "\n"
            "The primary checkout must be on the default branch. Uncommitted changes there are left\n"
            "alone, and landing refuses only when the branch also changes those paths, because git\n"
            "cannot fast-forward over them. Nothing here commits: commit inside the worktree first.\n"
            "\n"
            "A conflict pauses the rebase inside the worktree: resolve it there, then\n"
            "`wt apply --continue <name>`, or `wt apply --abort <name>` to put the branch back."
        ),
    )
    apply.add_argument("--dry-run", action="store_true", help="show what would be done")
    apply.add_argument("--remove", action="store_true", help="delete the worktree and branch once landed")
    apply.add_argument(
        "--abort-on-conflict", action="store_true", help="abort the rebase on conflict instead of pausing"
    )
    apply.add_argument("--continue", dest="continue_rebase", action="store_true", help="finish a paused rebase, then land")
    apply.add_argument("--abort", action="store_true", help="abort a paused rebase")
    apply.add_argument("target", nargs="?", help="worktree name, or . for the current one")
    apply.set_defaults(func=cmd_apply)

    sync = _verb(
        sub,
        "sync",
        help="Rebase a worktree onto local default",
        description="Rebase a worktree onto the local default branch without landing anything.",
        epilog=(
            "The catch-up verb: the worktree must be clean, and sync never touches the primary\n"
            "checkout and never removes anything. A conflict pauses the rebase inside the worktree:\n"
            "resolve it, then `wt sync --continue <name>`, or `wt sync --abort <name>`."
        ),
    )
    sync.add_argument("--dry-run", action="store_true", help="show what would be done")
    sync.add_argument(
        "--abort-on-conflict", action="store_true", help="abort the rebase on conflict instead of pausing"
    )
    sync.add_argument("--continue", dest="continue_rebase", action="store_true", help="finish a paused rebase")
    sync.add_argument("--abort", action="store_true", help="abort a paused rebase")
    sync.add_argument("target", nargs="?", help="worktree name, or . for the current one")
    sync.set_defaults(func=cmd_sync)

    diff = _verb(
        sub,
        "diff",
        help="Review a worktree diff",
        description="Review a worktree's changes against the default branch.",
        epilog=(
            "Opens diffnav on the merge base; --stat, --name-only and --patch print instead.\n"
            "Untracked files are called out, not shown in the diff."
        ),
    )
    diff.add_argument("--stat", action="store_true")
    diff.add_argument("--name-only", action="store_true")
    diff.add_argument("--patch", action="store_true")
    diff.add_argument("target", nargs="?")
    diff.set_defaults(func=cmd_diff)

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

    migrate = _verb(
        sub,
        "migrate",
        help="Move worktrees outside the root into it",
        description="Move this repository's worktrees that live outside the shared root into it.",
        epilog=(
            "A worktree git refuses to move (locked, or holding submodules) is named along with the\n"
            "command that unlocks it. Orphan directories outside the root are left for a person to\n"
            "inspect rather than moved."
        ),
    )
    migrate.add_argument("--dry-run", action="store_true")
    migrate.set_defaults(func=cmd_migrate)

    names = _verb(
        sub,
        "names",
        help="Print every worktree name",
        description="Print every worktree name, one per line, for completion and pickers.",
    )
    names.set_defaults(func=cmd_names)

    guard = _verb(
        sub,
        "guard",
        help="Refuse git worktree add/move outside the root",
        description="Refuse a `git worktree add` or `git worktree move` that would land outside the shared root.",
        epilog=(
            "The agent hooks (pi, Claude Code, opencode) run this on each shell command before it\n"
            "runs. It prints why it refused and exits 1, or prints nothing and exits 0.\n"
            "Worktrees live in <root>/<repo>/, never inside a checkout."
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
