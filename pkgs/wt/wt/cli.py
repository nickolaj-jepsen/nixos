"""Argument parsing and dispatch for the wt command."""

from __future__ import annotations

import argparse
import sys
from typing import Optional

from .commands import cmd_cd, cmd_close, cmd_drop, cmd_list, cmd_new
from .land import cmd_land


def _verb(sub: argparse._SubParsersAction, name: str, help: str, description: str, epilog: Optional[str] = None):
    return sub.add_parser(
        name, help=help, description=description, epilog=epilog, formatter_class=argparse.RawDescriptionHelpFormatter
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wt",
        description="Git worktrees you can throw away: the branch holds the work, the folder does not.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Worktrees live in <root>/<repo>/<name> (root: WT_WORKTREE_ROOT, default ~/worktrees).\n"
            "\n"
            "  wt new <name>     start work, or reopen a closed worktree as it was left\n"
            "  wt land [name]    put it in <default>, locally or through a PR, then close it\n"
            "  wt close [name]   commit what is uncommitted as a wip commit, remove the folder,\n"
            "                    and delete the branch once its work is in <default>\n"
            "\n"
            "Closing never loses work, so agent sessions close their own worktree when they exit.\n"
            "<default> is the branch origin/HEAD names, else main, else master."
        ),
    )
    sub = parser.add_subparsers(dest="verb", metavar="<verb>")

    new = _verb(
        sub,
        "new",
        "Start a worktree, or reopen a closed one",
        "Create a worktree on a new branch, or reopen a closed one, and print its path.",
        "A new branch starts from <base>, by default origin/<default> (fetched when over a day old),\n"
        "else <default>. A name that is already open just prints its path. Reopening checks out\n"
        "the branch the worktree was closed on and turns a wip commit at its tip back into\n"
        "uncommitted changes. Gitignored paths listed in the primary checkout's .worktreeinclude\n"
        "are copied in.",
    )
    new.add_argument("name", help="worktree and branch name; slashes become dashes in the folder name")
    new.add_argument("base", nargs="?", help="ref a new branch starts from")
    new.set_defaults(func=cmd_new)

    land = _verb(
        sub,
        "land",
        "Land a worktree in the default branch, then close it",
        "Rebase a worktree onto <default>, fast-forward <default> onto it, then close the worktree.",
        "Commit first: land refuses uncommitted changes and a wip commit at the tip. When the\n"
        "checkout holding <default> has uncommitted changes, landing leaves them alone and refuses\n"
        "only when the branch changes the same paths. When a session works in the worktree (this\n"
        "one included), it stays open and closes when that session ends.\n"
        "\n"
        "A conflict pauses the rebase inside the worktree: resolve it there, then\n"
        "`wt land --continue <name>`, or `wt land --abort <name>` to put the branch back.\n"
        "\n"
        "Through GitHub instead (needs gh and an origin remote):\n"
        "  --draft  push and open a draft PR          --pr  push and open a PR ready for review\n"
        "  --green  open it and merge on green: GitHub auto-merges (--rebase) when <default>\n"
        "           requires checks; otherwise this waits for the checks, up to --timeout, and a\n"
        "           rerun resumes the wait.\n"
        "A branch never pushed is rebased onto origin/<default> first; a pushed one is only pushed\n"
        "on, never forced. Without --title/--body-file, gh fills both from the commits. A worktree\n"
        "holding a gh stack submits the whole stack (gh stack submit), and --green merges it with\n"
        "gh stack merge once every layer's checks pass. The worktree closes afterwards; its branch\n"
        "stays until the PR merges, and the next `wt close` anywhere in the repo deletes it then.",
    )
    land.add_argument("target", nargs="?", help="worktree name, path, or . (default) for the current one")
    land.add_argument("--dry-run", action="store_true", help="say what would happen")
    land.add_argument("--abort-on-conflict", action="store_true", help="abort the rebase on conflict instead of pausing")
    land.add_argument("--continue", dest="continue_rebase", action="store_true", help="finish a paused rebase, then land")
    land.add_argument("--abort", action="store_true", help="abort a paused rebase")
    mode = land.add_mutually_exclusive_group()
    mode.add_argument("--draft", dest="mode", action="store_const", const="draft", help="open a draft PR")
    mode.add_argument("--pr", dest="mode", action="store_const", const="pr", help="open a PR ready for review")
    mode.add_argument("--green", dest="mode", action="store_const", const="green", help="open a PR and merge it on green")
    land.add_argument("--title", help="PR title")
    land.add_argument("--body-file", help="PR body, from a file")
    land.add_argument("--timeout", default="30m", help="how long --green waits for checks (default 30m)")
    land.set_defaults(func=cmd_land)

    close = _verb(
        sub,
        "close",
        "Remove a worktree's folder, keeping its work on the branch",
        "Commit any uncommitted changes as a wip commit, remove the folder, and delete the branch\n"
        "when all its commits are in <default>.",
        "A kept branch reopens with `wt new <name>`, wip commit undone. Refuses mid-rebase, merge\n"
        "or conflict, and while a process works inside; --when-free instead waits in the\n"
        "background until the folder is empty (an hour at most), which is what session-exit\n"
        "hooks run.",
    )
    close.add_argument("target", nargs="?", help="worktree name, path, or . (default) for the current one")
    close.add_argument("--when-free", action="store_true", help="close in the background once nothing works inside")
    close.set_defaults(func=cmd_close)

    drop = _verb(
        sub,
        "drop",
        "Throw a worktree's branch away",
        "Delete a worktree and its branch, landed or not, and print how to get it back.",
        "Uncommitted changes are committed first, so the printed sha holds everything.",
    )
    drop.add_argument("name")
    drop.set_defaults(func=cmd_drop)

    listing = _verb(
        sub,
        "list",
        "Show worktrees, open and closed",
        "Show this repository's worktrees, open and closed.",
        "AHEAD counts commits not in <default>, or says landed. DIRTY is yes for uncommitted\n"
        "changes and wip for a closed worktree holding a wip commit.\n"
        "--json prints {version, repos[]}, each repository {name, main, defaultBranch, worktrees[]}\n"
        "and each worktree {name, branch, path, open, ahead, landed, dirty, wip, busy, idleSeconds}.",
    )
    listing.add_argument("target", nargs="?", help="narrow to one worktree: name, path, or .")
    listing.add_argument("--all", action="store_true", help="every repository under the root")
    listing.add_argument("--json", action="store_true", help="machine-readable")
    listing.add_argument("--name", action="store_true", help="names only, one per line")
    listing.set_defaults(func=cmd_list)

    cd = _verb(
        sub,
        "cd",
        "Print an open worktree's path",
        "Print an open worktree's path, or the primary checkout's with --main.",
        "For `cd $(wt cd <name>)`, which moves a shell without moving an agent's session.",
    )
    cd.add_argument("target", nargs="?")
    cd.add_argument("--main", action="store_true", help="the primary checkout")
    cd.set_defaults(func=cmd_cd)

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
