"""The worktree-layout guard agent hooks run before shell commands."""

from __future__ import annotations

import argparse
import os
import re
from typing import Optional

from .git import git, is_within, normpath
from .repo import worktree_root


def shell_tokens(command: str) -> list[str]:
    tokens: list[str] = []
    word: list[str] = []
    have = False
    index = 0
    length = len(command)
    while index < length:
        char = command[index]
        if char in " \t\r":
            if have:
                tokens.append("".join(word))
                word = []
                have = False
        elif char in "\n;|&()":
            if have:
                tokens.append("".join(word))
                word = []
                have = False
            tokens.append("__SEP__")
        elif char in "'\"":
            quote = char
            index += 1
            while index < length and command[index] != quote:
                if quote == '"' and command[index] == "\\" and index + 1 < length:
                    index += 1
                word.append(command[index])
                index += 1
            have = True
        elif char == "\\":
            index += 1
            if index < length:
                word.append(command[index])
            have = True
        else:
            word.append(char)
            have = True
        index += 1
    if have:
        tokens.append("".join(word))
    return tokens


WRAPPERS = {"command", "builtin", "exec", "nohup", "time", "nice", "sudo", "env"}
GIT_GLOBAL_WITH_VALUE = {"-C", "-c"}
GIT_GLOBAL_FLAGS = {
    "-p", "-P", "--paginate", "--no-pager", "--bare", "--no-replace-objects",
    "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs",
    "--icase-pathspecs", "--no-optional-locks", "--no-advice",
}
DYNAMIC = re.compile(r"[$`]")


def _resolve(token: str, base: Optional[str]) -> Optional[str]:
    """`token` as an absolute path against `base`, or None when either is unknowable."""
    if not token or DYNAMIC.search(token):
        return None
    if base is None and not os.path.isabs(token):
        return None
    return normpath(token, base)


def guard_command(command: str) -> tuple[bool, str]:
    """Return (blocked, reason) for a shell command."""
    root_base = worktree_root()
    tokens = shell_tokens(command)
    index = 0
    at_start = True
    # None once a dynamic `cd`/`-C` makes it unknowable; only a relative add/move path then blocks.
    cwd: Optional[str] = os.getcwd()
    while index < len(tokens):
        token = tokens[index]
        if token == "__SEP__":
            at_start = True
            index += 1
            continue
        if at_start:
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token):
                index += 1
                continue
            if token in WRAPPERS:
                index += 1
                continue
            if token == "cd":
                target = tokens[index + 1] if index + 1 < len(tokens) else ""
                cwd = _resolve(target, cwd)
                index += 2
                at_start = False
                continue
            if token == "git" or token.endswith("/git"):
                invocation_cwd = cwd
                cursor = index + 1
                while cursor < len(tokens):
                    value = tokens[cursor]
                    if value in GIT_GLOBAL_WITH_VALUE:
                        if value == "-C" and cursor + 1 < len(tokens):
                            invocation_cwd = _resolve(tokens[cursor + 1], invocation_cwd)
                        cursor += 2
                        continue
                    if value.startswith("--git-dir=") or value.startswith("--work-tree=") or value.startswith("--exec-path=") or value.startswith("--namespace=") or value.startswith("--config-env=") or value.startswith("--super-prefix="):
                        cursor += 1
                        continue
                    if value in GIT_GLOBAL_FLAGS or value.startswith("-"):
                        cursor += 1
                        continue
                    break
                if cursor < len(tokens) and tokens[cursor] == "worktree" and cursor + 1 < len(tokens):
                    sub = tokens[cursor + 1]
                    if sub in ("add", "move"):
                        cursor += 2
                        branch = ""
                        paths: list[str] = []
                        while cursor < len(tokens) and tokens[cursor] != "__SEP__":
                            value = tokens[cursor]
                            if value == "--":
                                cursor += 1
                                if cursor < len(tokens) and tokens[cursor] != "__SEP__":
                                    paths.append(tokens[cursor])
                                    cursor += 1
                                break
                            if value in ("-b", "-B"):
                                branch = tokens[cursor + 1] if cursor + 1 < len(tokens) else ""
                                cursor += 2
                                continue
                            if value == "--reason":
                                cursor += 2
                                continue
                            if value.startswith("-"):
                                cursor += 1
                                continue
                            paths.append(value)
                            cursor += 1
                        checked = paths[-1:] if sub == "move" else paths[:1]
                        for path in checked:
                            resolved = _resolve(path, invocation_cwd)
                            if resolved is None:
                                return True, guard_reason(path, branch, dynamic=True)
                            if not is_within(resolved, root_base):
                                return True, guard_reason(path, branch)
                        index = cursor
                        at_start = False
                        continue
                if cursor < len(tokens) and tokens[cursor] in ("switch", "checkout"):
                    end = cursor + 1
                    while end < len(tokens) and tokens[end] != "__SEP__":
                        end += 1
                    reason = branch_switch_reason(tokens[cursor], tokens[cursor + 1 : end], invocation_cwd)
                    if reason:
                        return True, reason
                index = cursor
                at_start = False
                continue
            at_start = False
        index += 1
    return False, ""


# `git checkout` flags that move HEAD off the worktree's branch.
CHECKOUT_SWITCH_FLAGS = {"-b", "-B", "--orphan", "--detach"}


def branch_switch_reason(verb: str, args: list[str], cwd: Optional[str]) -> str:
    """Why `git <verb> <args>` run in `cwd` is refused, or "" when it is not a branch switch inside a wt worktree."""
    if cwd is None or "-h" in args or "--help" in args:
        return ""
    flagged = bool(CHECKOUT_SWITCH_FLAGS.intersection(args)) or "-" in args
    positional = [arg for arg in args if not arg.startswith("-")]
    if verb == "checkout" and ("--" in args or (not flagged and len(positional) != 1)):
        return ""
    root = os.path.realpath(worktree_root())
    top = git(cwd, "rev-parse", "--show-toplevel", check=False).strip()
    if not top or not is_within(os.path.realpath(top), root) or os.path.realpath(top) == root:
        return ""
    if verb == "checkout" and not flagged:
        # A lone argument is a branch or a path; only a branch moves HEAD.
        name = positional[0]
        if not git(top, "for-each-ref", "--count=1", f"refs/heads/{name}", f"refs/remotes/*/{name}", check=False).strip():
            return ""
    branch = git(top, "branch", "--show-current", check=False).strip() or "<branch>"
    return (
        f"Blocked: switching branches inside the worktree {top}, which holds '{branch}'.\n"
        f"A worktree's branch is its name, and wt finds worktrees by name, so the folder\n"
        f"would keep naming '{branch}' while holding another. A new branch gets its own worktree:\n"
        f"  wt create <name> {branch}   # stacked on this branch; leave it off for the default branch\n"
        f"then move the session into it. Restoring files (`git checkout -- <path>`, `git restore`) is fine."
    )


def guard_reason(path: str, branch: str, *, dynamic: bool = False) -> str:
    name = os.path.basename(path) if path else ""
    name = name or "<name>"
    branch = branch or "<branch>"
    why = (
        "The path, or the directory it is relative to, uses a variable or command substitution,\n"
        "so wt cannot tell where it lands."
        if dynamic
        else "Worktrees live in the shared root, never inside a checkout."
    )
    return (
        f"Blocked: git worktree add/move outside the shared worktree root.\n"
        f"{why}\n"
        f"Worktrees live in {worktree_root()}/<repo>/, never inside a checkout.\n"
        f"Use one of:\n"
        f"  wt create {name} <base>                 # new branch off <base> (default: the default branch)\n"
        f"  wt remove {name}                        # remove a worktree (archives forced work)\n"
        f"  git worktree add {worktree_root()}/<repo>/{name} {branch}  # keeps the branch you asked for"
    )


def cmd_guard(args: argparse.Namespace) -> None:
    blocked, reason = guard_command(args.command)
    if blocked:
        print(reason)
        raise SystemExit(1)
