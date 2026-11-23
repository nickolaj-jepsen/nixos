# Agent notes

Notes and the artifacts they name outlive the session that wrote them, so they
live outside the checkout but visible inside it: every checkout exposes
`.agents/store`, `.agents/workflows`, `.agents/tmp` and `.agents/claude-memory` as symlinks into the
agents' own directories.

- A note is Markdown under the store; git never holds one, so no commit, stash,
  rebase or reset can lose one.
- `git clean -xdf` removes the link and leaves the store, because the link is
  ignored and the store is not beneath it.
- A committed `.agents/skills/` still works: only the link paths are ignored
  and only they are touched.
- The CLI is `pkgs/agent-notes`, wired in by `modules/programs/agent-notes.nix`
  and scheduled by nothing: the git hook and the agent wrappers call it.

## Where a note lives

```text
${XDG_DATA_HOME:-~/.local/share}/agents/store/<repo-id>/
  plans/<slug>/{PLAN.md,HANDOFF.md,PROGRESS.md,notes/,files/,history/}
  workflows/<slug>/{spec.md,research.md,tickets/}
  research/<topic>/{REPORT.md,notes/,files/}
  ideas/<focus>.md
  findings/<target>.md
  onboard/{overview.md,<subsystem>.md,files/{assets,devshell}/}

${XDG_DATA_HOME:-~/.local/share}/agents/claude-memory/<repo-id>/   Claude Code auto-memory
${XDG_STATE_HOME:-~/.local/state}/agents/tmp/<repo-id>/<pid>/   scratch, reaped
~/.local/share/agents/_orphaned/                                migration only
```

- `<repo-id>` is the main checkout's directory name plus eight hex digits of a
  hash of its real path. Every worktree of a checkout shares one id, two
  checkouts that share a basename do not, and a submodule is its own repository.
- A working directory outside git uses `global`.
- The id comes from `git worktree list --porcelain`'s first entry, so moving or
  renaming the main checkout strands its store under the old id. Move the store
  directory to the new id, or let the next write start a fresh one.
- `.agents/workflows/<slug>/` opens `workflows/<slug>/` in the same durable store.
  Run `agent-notes root --ensure` before the first write.
- `files/` holds what a note names: captured output, images, a generated
  devshell. `/open plan` does not list Markdown in there as a note, so a generated
  report never looks like something a session wrote.
- `history/` holds superseded copies, such as `run-handoff`'s archived
  `plans/history/<slug>/`. It is not listed either.
- `claude-memory/<repo-id>/` is Claude Code's auto-memory, kept beside the store
  rather than in it; a checkout sees it as `.agents/claude-memory`. Both `claude` wrappers pass it as `autoMemoryDirectory`
  (flag settings), so every worktree and the work profile share one memory per
  repository. Outside git, Claude Code keeps its per-cwd default under
  `~/.claude/projects/`.

## The commands

`agent-notes --help` lists them. Skills call `agent-notes root --ensure`, which
creates the store and repairs the links.

`init` refuses to replace a real file, a real directory, a symlink pointing
somewhere else, or a path git tracks. It prints why and exits zero, because git
hands a `post-checkout` hook's status back to the checkout that ran it.

## The links, and what makes them

- `hook.agent-notes` in the global git config (`modules/programs/git.nix`) is a
  config-based `post-checkout` hook. Git 2.54 runs those beside a repository's own
  `post-checkout` instead of replacing it, so no `core.hooksPath` takeover and no
  dispatcher is needed.
- It fires for `git clone`, `git switch`, `git checkout` and `git worktree add`.
  Git older than 2.54 ignores the section, `git clone --no-checkout` fires
  nothing, and a clone made by a GUI that runs no hooks gets no links either.
- The links are a view, not the truth: `agent-notes init` at session start
  repairs what the hook missed, and every skill resolves through
  `agent-notes root --ensure` rather than assuming the link exists.
- The hook creates the links, never the store. A clone that is thrown away
  therefore leaves nothing behind, and a brand-new project's `.agents/store`
  dangles until something writes a note.
- All four link paths are root-anchored in the global Git ignore file. A path git already tracks is unaffected by an ignore rule, which
  is why `init` checks rather than assumes.

## Scratch

- The `pi` and `pi-work` wrappers export `TMPDIR=$(agent-notes tmp "$$")`, so
  an agent's temp files sit beside its notes under the repository it is working
  in.
- The `claude` and `claude-work` wrappers export `TMPDIR=$(agent-notes tmp --repo)`
  instead: Claude Code nests its scratchpad by session id under it, so a resumed
  session keeps its scratchpad, which a new pid would lose.
- `agent-notes reap` ages out everything under `<state>/agents/tmp/<repo>/`
  untouched for three days, on a daily user timer in
  `modules/programs/agent-notes.nix` (Linux only). The repository directories
  themselves stay, so a checkout's `.agents/tmp` link never dangles. A session
  idle that long loses its old files too: there is no liveness check.
- It is not a `systemd-tmpfiles` rule, because tmpfiles stamps out on the first
  directory it may not open or unlink and leaves the rest of that session alone:
  Go's module cache is read-only, and a test bed can leave a `d---------`
  directory owned by another uid. `reap` makes a read-only tree writable first
  and removes an empty directory it cannot enter, and it logs whatever is left
  as not ours rather than retrying it every day.
- On the desktop, `.local/state/agents/tmp` is a nested subvolume, apart from
  `@home` (`hosts/desktop/filesystems.nix`).

## Migration

`agent-notes migrate` moves a host's notes from the old layout (every project a
bare name under the data root). It reports first and changes nothing until
`--apply`; stop live sessions before applying, because a note written through
an old path during the run is missed.

## Editing a note in the editor

`/open plan` in pi and Claude Code lists the store's notes, newest first, and
opens the picked one through `agent-note-open` (`modules/scripts`), as does a
clicked `file://` link to a note's store path in Kitty on Linux.
Zed indexes the store through the link and excludes `.agents/tmp`.

## Traps

- Two checkouts of one upstream keep separate notes: the identity is the
  checkout, not the remote.
- `git clean -xdf` removes the links; run `agent-notes init` to get them back.
  Nothing in the store is lost.
- `git worktree move` and a `mv` of the main checkout change the path the id
  hashes, so the old store stops being found.
- `/home` is not snapshotted and the store is not in any off-host backup.
