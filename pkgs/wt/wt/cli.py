"""Argument parsing and dispatch for the wt command."""

from __future__ import annotations

import argparse
import sys
from typing import Optional

from .clean import cmd_clean
from .commands import cmd_cd, cmd_close, cmd_drop, cmd_list, cmd_new
from .git import ProbeError, die
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
            "  wt clean          pick which worktrees with nothing uncommitted to close\n"
            "\n"
            "Closing never loses work, and nothing closes a worktree on its own.\n"
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
        "else <default>. An open name just prints its path. Reopening checks out the branch the\n"
        "worktree was closed on and turns a wip commit at its tip back into uncommitted changes.\n"
        "Gitignored paths listed in the primary checkout's .worktreeinclude are copied in. Its\n"
        "submodules are cloned from it, with their listed paths copied when both are on the same\n"
        "commit.",
    )
    new.add_argument("name", help="worktree and branch name; slashes become dashes in the folder name")
    new.add_argument("base", nargs="?", help="ref a new branch starts from")
    new.set_defaults(func=cmd_new)

    land = _verb(
        sub,
        "land",
        "Land a worktree, or the primary checkout, in the default branch",
        "Rebase a worktree onto <default>, fast-forward <default> onto it, then close the worktree.",
        "Commit first: land refuses uncommitted changes and a wip commit at the tip. Uncommitted\n"
        "changes in the checkout holding <default> are left alone; landing refuses only when the\n"
        "branch changes the same paths. From inside the worktree, it stays open for `wt clean`.\n"
        "\n"
        "A conflict pauses the rebase in the worktree: resolve it there, then\n"
        "`wt land --continue <name>`, or `wt land --abort <name>` to put the branch back.\n"
        "\n"
        "Through GitHub instead (needs gh and an origin remote):\n"
        "  --draft  push and open a draft PR          --pr  push and open a PR ready for review\n"
        "  --green  open a PR and merge on green: GitHub auto-merges (rebase) when <default>\n"
        "           requires checks, else this waits for them, up to --timeout; a rerun resumes.\n"
        "A branch never pushed is rebased onto origin/<default> first; a pushed one is only pushed\n"
        "on, never forced. gh fills the title and body from the commits unless --title/--body-file.\n"
        "A worktree holding a gh stack submits the whole stack, and --green merges it once every\n"
        "layer's checks pass. The worktree closes afterwards; its branch stays until the PR\n"
        "merges, and the next `wt close` anywhere in the repo deletes it then.\n"
        "\n"
        "From the primary checkout (`.` there, or the branch it has checked out), uncommitted\n"
        "changes are left alone unless a step would overwrite one:\n"
        "  on <default>  push it to origin, fast-forward only. When origin/<default> is ahead this\n"
        "                refuses unless --rebase, which rebases <default> onto it first (uncommitted\n"
        "                changes autostashed). --draft/--pr/--green need --branch <name>: the\n"
        "                unpushed commits move to that new branch, the checkout switches to it, and\n"
        "                local <default> goes back to origin's.\n"
        "  on a branch   rebase it onto <default>, fast-forward <default>, switch to it, and delete\n"
        "                the branch. Through a PR the checkout stays on the branch until the PR\n"
        "                merges, then switches to <default>, fast-forwards to origin's and deletes\n"
        "                the branch. Refused while <default> is checked out in a worktree, and for\n"
        "                a gh stack.",
    )
    land.add_argument("target", nargs="?", help="worktree name, path, branch, or . (default) for the current checkout")
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
    land.add_argument("--rebase", action="store_true", help="primary checkout on <default>: rebase it onto origin's first")
    land.add_argument("--branch", help="primary checkout on <default>: the new branch a PR's commits move to")
    land.set_defaults(func=cmd_land)

    close = _verb(
        sub,
        "close",
        "Remove a worktree's folder, keeping its work on the branch",
        "Commit any uncommitted changes as a wip commit, remove the folder, and delete the branch\n"
        "when all its commits are in <default>.",
        "A kept branch reopens with `wt new <name>`, wip commit undone. Refuses mid-rebase, merge\n"
        "or conflict, with unsaved work in a submodule, and from inside the folder. Gitignored\n"
        "files (.env, build output, result links) go with the folder; `wt new` copies back the\n"
        "paths in the primary checkout's .worktreeinclude.",
    )
    close.add_argument("target", nargs="?", help="worktree name, path, or . (default) for the current one")
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

    clean = _verb(
        sub,
        "clean",
        "Close the worktrees that hold nothing uncommitted",
        "Close open worktrees with no uncommitted changes: in a terminal, pick which in fzf.",
        "Committed work stays on the branch, which goes too only when all its commits are in\n"
        "<default> (COMMITS +0). Rows show the commits ahead of and behind <default>, when the\n"
        "worktree last changed, and its last commit; the picker previews the commits not in\n"
        "<default>. Worktrees with uncommitted changes, a lock, or this shell in them are left,\n"
        "and named on stderr.\n"
        "\n"
        "Without a terminal it only lists them; --yes closes every one listed. Outside a\n"
        "repository it covers every repository under the root, as --all does.",
    )
    clean.add_argument("--all", action="store_true", help="every repository under the root")
    clean.add_argument("--dry-run", action="store_true", help="list what could be closed and close nothing")
    clean.add_argument("--yes", action="store_true", help="close every one listed, without picking")
    clean.set_defaults(func=cmd_clean)

    listing = _verb(
        sub,
        "list",
        "Show worktrees, open and closed",
        "Show this repository's worktrees, open and closed.",
        "AHEAD counts commits not in <default>, or says landed. DIRTY is yes for uncommitted\n"
        "changes and wip for a closed worktree holding a wip commit.\n"
        "--json prints {version, repos[]}, each repository {name, main, defaultBranch, error,\n"
        "worktrees[]} and each worktree {name, branch, path, open, ahead, behind, landed, dirty,\n"
        "wip, idleSeconds, error}. A value git could not answer is null, with the reason in that\n"
        "row's error (a table prints ?). Healthy rows beside a broken one still print; the exit\n"
        "is 1 if anything could not be inspected, else 0.",
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
        "For `cd $(wt cd <name>)`: moves a shell, not an agent's session.",
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
    except ProbeError as error:
        # A probe that reached here is a mutation's unanswered question: stop with git's reason.
        die(str(error))
    except SystemExit as exc:
        return int(exc.code or 0)
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
