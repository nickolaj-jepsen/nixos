"""wt clean: remove the folders of open worktrees that hold no uncommitted work.

Committed work is safe on the branch whatever its state, so the only thing that keeps a folder is
what is not committed yet. Removing goes through `close`, so a branch whose commits are all in the
default branch, or whose pull request merged at its tip, goes too and every other branch stays.
The picker starts with exactly those worktrees ticked: closing them leaves nothing behind.
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass

from .commands import close_entry, format_age
from .gh import pr_merged
from .git import ProbeError, info, is_within, probe
from .repo import Located, Repo, RepoLock, current_repo, discover_common, repos_under_root
from .worktrees import Entry, Row, dirty, entries, inspect_row, read_only_git, resolve

UNKNOWN = "?"


@dataclass
class Candidate:
    repo: Repo
    entry: Entry
    row: Row
    subject: str
    # Why closing it leaves nothing behind (its commits are in the default branch, or its PR
    # merged); empty when its branch still holds work the default branch lacks.
    finished: str = ""


def _subject(path: str) -> str:
    try:
        return probe(path, "log", "-1", "--format=%s", "HEAD", "--").strip()
    except ProbeError:
        return ""


def _finished(repo: Repo, entry: Entry, row: Row) -> str:
    """Why closing `entry` loses nothing, judged as `close` judges when it deletes the branch."""
    if row.landed:
        return f"its commits are in {repo.default}"
    if entry.branch and row.landed is False:
        try:
            sha = probe(entry.path or "", "rev-parse", "HEAD").strip()
        except ProbeError:
            return ""
        if pr_merged(repo, entry.branch, sha):
            return "its pull request merged"
    return ""


def everywhere(args: argparse.Namespace) -> bool:
    """Whether clean covers every repository under the root: asked to, or outside any repository."""
    return args.all or discover_common(os.getcwd()) is None


def gather(args: argparse.Namespace) -> tuple[list[Candidate], list[str]]:
    """The worktrees clean may remove, and a line for each it leaves and why."""
    found: list[Candidate] = []
    left: list[str] = []
    cwd = os.path.realpath(os.getcwd())
    every = everywhere(args)
    with read_only_git():
        if every:
            scope = repos_under_root()
        else:
            here = current_repo(create=False)
            scope = [Located(name=here.key, repo=here)]
        for item in scope:
            repo = item.repo
            if repo is None:
                left.append(f"{item.name}: {item.error}")
                continue
            try:
                selected = entries(repo)
            except ProbeError as error:
                left.append(f"{repo.key}: {error}")
                continue
            for entry in selected:
                if not entry.open:
                    continue
                label = f"{repo.key}/{entry.name}" if every else entry.name
                path = entry.path or ""
                if entry.locked:
                    left.append(f"{label}: locked")
                    continue
                if is_within(cwd, os.path.realpath(path)):
                    left.append(f"{label}: you are in it")
                    continue
                row = inspect_row(repo, entry)
                if row.dirty is None:
                    left.append(f"{label}: could not tell whether it has uncommitted changes: {row.error}")
                elif row.dirty:
                    left.append(f"{label}: uncommitted changes")
                else:
                    found.append(Candidate(repo, entry, row, _subject(path), _finished(repo, entry, row)))
    return found, left


def _counts(row: Row) -> str:
    ahead = UNKNOWN if row.ahead is None else str(row.ahead)
    behind = UNKNOWN if row.behind is None else str(row.behind)
    return f"+{ahead} -{behind}"


def _changed(row: Row) -> str:
    return UNKNOWN if row.idle_seconds is None else f"{format_age(row.idle_seconds)} ago"


def _after(candidate: Candidate) -> str:
    """What becomes of the branch when the folder goes."""
    if not candidate.entry.branch:
        return "-"
    return "deleted" if candidate.finished else "kept"


def _cells(candidate: Candidate, with_repo: bool) -> list[str]:
    row = candidate.row
    cells = [candidate.repo.key] if with_repo else []
    return [
        *cells,
        row.name,
        row.branch or "(detached)",
        _counts(row),
        _after(candidate),
        _changed(row),
        candidate.subject,
    ]


def _table(candidates: list[Candidate], with_repo: bool) -> list[str]:
    header = (["REPO"] if with_repo else []) + ["NAME", "BRANCH", "COMMITS", "BRANCH AFTER", "CHANGED", "LAST COMMIT"]
    rows = [header, *(_cells(c, with_repo) for c in candidates)]
    widths = [max(len(row[i]) for row in rows) for i in range(len(header))]
    return ["  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip() for row in rows]


# The commits listed under the highlighted row before the rest are only counted.
_SHOWN = 6
# The widest a worktree's name gets in the checklist before it is cut.
_NAME_MAX = 36

_STYLE = [
    ("title", "bold"),
    ("dim", "ansibrightblack"),
    ("pointer", "ansicyan bold"),
    ("current", "bold"),
    ("on", "ansigreen"),
    ("off", "ansibrightblack"),
    ("ahead", "ansiyellow"),
    ("merged", "ansigreen"),
    ("unmerged", "ansiyellow"),
    ("key", "bold"),
]


def _state(candidate: Candidate) -> tuple[str, str]:
    """A word for whether the branch holds work the default branch lacks, and its style."""
    if not candidate.entry.branch:
        return "detached", "class:dim"
    if candidate.finished:
        return "merged", "class:merged"
    return "unmerged", "class:unmerged"


class _Checklist:
    """A checklist of the candidates, one aligned row each, with what closing the highlighted one leaves."""

    def __init__(self, candidates: list[Candidate], with_repo: bool) -> None:
        self.candidates = candidates
        self.with_repo = with_repo
        self.ticked = {i for i, c in enumerate(candidates) if c.finished}
        self.at = 0
        self._commits: dict[int, list[tuple[str, str, str]]] = {}
        rows = [c.row for c in candidates]
        self.labels = [self._label(c) for c in candidates]
        self.name_w = min(max(map(len, self.labels)), _NAME_MAX)
        self.ahead = [UNKNOWN if r.ahead is None else str(r.ahead) for r in rows]
        self.behind = [UNKNOWN if r.behind is None else str(r.behind) for r in rows]
        self.ahead_w = max(map(len, self.ahead)) + 1
        self.behind_w = max(map(len, self.behind)) + 1
        self.commits_w = max(len("COMMITS"), self.ahead_w + 1 + self.behind_w)
        self.ages = [UNKNOWN if r.idle_seconds is None else format_age(r.idle_seconds) for r in rows]
        self.age_w = max(len("AGE"), *map(len, self.ages))
        self.state_w = max(len("BRANCH"), *(len(_state(c)[0]) for c in candidates))
        # The columns a row spends before its last commit, the name's own aside.
        self.fixed_w = 4 + 2 + self.commits_w + 2 + self.state_w + 2 + self.age_w + 2

    def _label(self, candidate: Candidate) -> str:
        return f"{candidate.repo.key}/{candidate.entry.name}" if self.with_repo else candidate.entry.name

    @staticmethod
    def _width() -> int:
        from prompt_toolkit.application import get_app

        return get_app().output.get_size().columns - 1

    def title(self) -> list[tuple[str, str]]:
        return [
            ("class:title", "Close which worktrees?"),
            ("class:dim", f"  {len(self.ticked)} of {len(self.candidates)} ticked"),
        ]

    def _name_w(self, width: int) -> int:
        """The name column's width: it gives up room until the last commit has some."""
        return max(12, min(self.name_w, width - self.fixed_w - 24))

    def header(self) -> list[tuple[str, str]]:
        name_w = self._name_w(self._width())
        cells = [
            _pad("NAME", name_w),
            _pad("COMMITS", self.commits_w),
            _pad("BRANCH", self.state_w),
            _pad("AGE", self.age_w),
            "LAST COMMIT",
        ]
        return [("class:dim", _fit("    " + "  ".join(cells), self._width()))]

    def rows(self) -> list[tuple[str, str]]:
        width = self._width()
        name_w = self._name_w(width)
        out: list[tuple[str, str]] = []
        for i, candidate in enumerate(self.candidates):
            current = i == self.at
            ahead = self.ahead[i]
            state, state_style = _state(candidate)
            if current:
                out.append(("[SetCursorPosition]", ""))
            out += [
                ("class:pointer", "❯ ") if current else ("", "  "),
                ("class:on", "● ") if i in self.ticked else ("class:off", "○ "),
                ("class:current" if current else "", _pad(_fit(self.labels[i], name_w), name_w)),
                ("", "  "),
                ("class:ahead" if ahead not in ("0", UNKNOWN) else "class:dim", f"+{ahead}".rjust(self.ahead_w)),
                ("class:dim", _pad(" " + f"-{self.behind[i]}".ljust(self.behind_w), self.commits_w - self.ahead_w)),
                ("", "  "),
                (state_style, state.ljust(self.state_w)),
                ("", "  "),
                ("class:dim", self.ages[i].ljust(self.age_w)),
                ("", "  "),
            ]
            out.append(("", _fit(candidate.subject, width - self.fixed_w - name_w)))
            if i < len(self.candidates) - 1:
                out.append(("", "\n"))
        return out

    def _commits_of(self, i: int) -> list[tuple[str, str, str]]:
        if i not in self._commits:
            candidate = self.candidates[i]
            try:
                out = probe(
                    candidate.entry.path or "", "log", f"--max-count={_SHOWN}",
                    "--format=%h%x1f%s%x1f%cr", f"{candidate.repo.default}..HEAD", "--",
                )
            except ProbeError:
                out = ""
            self._commits[i] = [tuple(line.split("\x1f", 2)) for line in out.splitlines()]  # type: ignore[misc]
        return self._commits[i]

    def detail(self) -> list[tuple[str, str]]:
        """What closing the highlighted worktree removes, and the commits it leaves on the branch."""
        candidate = self.candidates[self.at]
        width = self._width()
        branch, base = candidate.entry.branch, candidate.repo.default
        # The branch is named only when it differs from the worktree, which it rarely does.
        named = [("", " "), ("class:current", branch)] if branch != candidate.entry.name else []
        if not branch:
            lines = [[("", "Removes the folder; its HEAD is detached.")]]
        elif candidate.finished:
            lines = [[("", "Removes the folder and the branch"), *named, ("class:dim", f": {candidate.finished}.")]]
        else:
            count = candidate.row.ahead
            noun = "commit" if count == 1 else "commits"
            lines = [[
                ("", "Removes the folder; the branch"), *named,
                ("", f" stays with {UNKNOWN if count is None else count} {noun} not in {base}:"),
            ]]
            for sha, subject, when in self._commits_of(self.at):
                lines.append([("class:dim", f"  {sha} "), ("", subject), ("class:dim", f"  {when}")])
            if count is not None and count > _SHOWN:
                lines.append([("class:dim", f"  … and {count - _SHOWN} more")])
        out: list[tuple[str, str]] = []
        for line in lines:
            out += [("", "\n  "), *_clip(line, width - 2)]
        return out

    def footer(self) -> list[tuple[str, str]]:
        n = len(self.ticked)
        keys = [
            ("space", "tick"), ("a", "all"), ("i", "invert"),
            ("enter", f"close {n}" if n else "close none"), ("esc", "cancel"),
        ]
        out: list[tuple[str, str]] = [("", "\n")]
        for j, (key, what) in enumerate(keys):
            out += [("", "  "), ("class:key", key), ("class:dim", f" {what}")]
        return out


def _fit(text: str, width: int) -> str:
    """`text` cut to `width` columns, an ellipsis marking the cut."""
    from prompt_toolkit.utils import get_cwidth

    if width <= 0:
        return ""
    if get_cwidth(text) <= width:
        return text
    kept, used = [], 0
    for char in text:
        used += get_cwidth(char)
        if used > width - 1:
            break
        kept.append(char)
    return "".join(kept) + "…"


def _clip(fragments: list[tuple[str, str]], width: int) -> list[tuple[str, str]]:
    """`fragments` cut to `width` columns; the fragment the cut falls in gives up room first."""
    from prompt_toolkit.utils import get_cwidth

    out: list[tuple[str, str]] = []
    total = sum(get_cwidth(text) for _, text in fragments)
    if total <= width:
        return fragments
    # Cut the widest fragment (a subject or a long branch), keeping the dim trailers whole.
    widest = max(range(len(fragments)), key=lambda j: get_cwidth(fragments[j][1]))
    for j, (style, text) in enumerate(fragments):
        if j == widest:
            text = _fit(text, get_cwidth(text) - (total - width))
        out.append((style, text))
    return out


def _pad(text: str, width: int) -> str:
    from prompt_toolkit.utils import get_cwidth

    return text + " " * max(0, width - get_cwidth(text))


def pick(candidates: list[Candidate], with_repo: bool) -> list[Candidate]:
    """The candidates ticked in a checklist, those that close with nothing left behind ticked to start; none when cancelled."""
    from prompt_toolkit.application import Application
    from prompt_toolkit.key_binding import KeyBindings
    from prompt_toolkit.layout import FormattedTextControl, HSplit, Layout, Window
    from prompt_toolkit.layout.dimension import Dimension
    from prompt_toolkit.styles import Style

    view = _Checklist(candidates, with_repo)
    n = len(candidates)
    keys = KeyBindings()

    def move(step: int) -> None:
        view.at = (view.at + step) % n

    keys.add("up")(lambda _: move(-1))
    keys.add("k")(lambda _: move(-1))
    keys.add("c-p")(lambda _: move(-1))
    keys.add("down")(lambda _: move(1))
    keys.add("j")(lambda _: move(1))
    keys.add("c-n")(lambda _: move(1))
    keys.add("home")(lambda _: setattr(view, "at", 0))
    keys.add("end")(lambda _: setattr(view, "at", n - 1))
    keys.add(" ")(lambda _: view.ticked.symmetric_difference_update({view.at}))
    keys.add("a")(lambda _: setattr(view, "ticked", set() if len(view.ticked) == n else set(range(n))))
    keys.add("i")(lambda _: setattr(view, "ticked", set(range(n)) - view.ticked))
    keys.add("enter")(lambda e: e.app.exit(result=sorted(view.ticked)))
    for cancel in ("escape", "c-c", "q"):
        keys.add(cancel, eager=True)(lambda e: e.app.exit(result=None))

    def text(get) -> Window:  # noqa: ANN001
        return Window(FormattedTextControl(get), dont_extend_height=True, always_hide_cursor=True)

    rows = Window(
        FormattedTextControl(view.rows, focusable=True, show_cursor=False),
        height=Dimension(min=1, max=n, preferred=n),
        always_hide_cursor=True,
        wrap_lines=False,
    )
    panes = HSplit([text(view.title), text(view.header), rows, text(view.footer), text(view.detail)])
    app: Application[list[int] | None] = Application(
        layout=Layout(panes, focused_element=rows),
        key_bindings=keys,
        style=Style(_STYLE),
        erase_when_done=True,
    )
    chosen = app.run()
    return [] if chosen is None else [candidates[i] for i in chosen]


def remove(candidates: list[Candidate]) -> int:
    """Close each chosen worktree, checking again under the lock; the number it left open."""
    failed = 0
    for candidate in candidates:
        repo, name = candidate.repo, candidate.entry.name
        try:
            with RepoLock(repo):
                entry = resolve(repo, name)
                path = entry.path or ""
                if not entry.open:
                    continue
                if dirty(path):
                    info(f"left {name}: it has uncommitted changes now")
                    failed += 1
                    continue
                close_entry(repo, entry)
        except ProbeError as error:
            info(f"left {name}: {error}")
            failed += 1
        except SystemExit:
            # die() already said why; one worktree that refuses must not stop the rest.
            failed += 1
    return failed


def cmd_clean(args: argparse.Namespace) -> None:
    candidates, left = gather(args)
    with_repo = everywhere(args)
    for line in left:
        info(f"left {line}")
    if not candidates:
        info("nothing to clean")
        return
    interactive = sys.stdin.isatty() and sys.stdout.isatty()
    if args.yes:
        chosen = candidates
    elif not args.dry_run and interactive:
        chosen = pick(candidates, with_repo)
        if not chosen:
            info("nothing removed")
            return
    else:
        print("\n".join(_table(candidates, with_repo)))
        if not args.dry_run:
            info("nothing removed: pass --yes to remove these folders, or run it in a terminal to pick")
        return
    if remove(chosen):
        raise SystemExit(1)
