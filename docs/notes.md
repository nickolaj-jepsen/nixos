# Agent notes

Notes and the artifacts they name outlive the session that wrote them, so they
live outside the checkout but visible inside it: every checkout exposes
`.agents/store` and `.agents/tmp` as symlinks into the agents' own directories.

- A note is Markdown under the store; git never holds one, so no commit, stash,
  rebase or reset can lose one.
- `git clean -xdf` removes the link and leaves the store, because the link is
  ignored and the store is not beneath it.
- A committed `.agents/skills/` still works: only the two link paths are ignored
  and only they are touched.
- The CLI is `pkgs/agent-notes`, wired in by `modules/programs/agent-notes.nix`
  and scheduled by nothing: the git hook and the agent wrappers call it.

## Where a note lives

```text
${XDG_DATA_HOME:-~/.local/share}/agents/store/<repo-id>/
  plans/<slug>/{PLAN.md,HANDOFF.md,PROGRESS.md,notes/,files/,history/}
  research/<topic>/{REPORT.md,notes/,files/}
  ideas/<focus>.md
  findings/<target>.md
  onboard/{overview.md,<subsystem>.md,files/{assets,devshell}/}

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
- `files/` holds what a note names: captured output, images, a generated
  devshell. `/open plan` does not list Markdown in there as a note, so a generated
  report never looks like something a session wrote.
- `history/` holds superseded copies, such as `annotate-plan`'s
  `history/PLAN.prev.md`. It is not listed either.

## The commands

```bash
agent-notes root                  # the store directory for this checkout (not created)
agent-notes root --ensure         # create it, and repair the links
agent-notes tmp [PID]             # this session's scratch directory, created
agent-notes init                  # create or repair the links; quiet, never fails
agent-notes id                    # the repo-id alone
agent-notes status                # id, paths, and what state each link is in
agent-notes migrate [--apply]     # the old per-project layout, moved
```

`init` refuses to replace a real file, a real directory, a symlink pointing
somewhere else, or a path git tracks. It prints why it left one alone and exits
zero, because git hands a `post-checkout` hook's status back to the checkout that
ran it.

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
- Ignored by `/.agents/store` and `/.agents/tmp`, root-anchored, in the global
  ignore file. A path git already tracks is unaffected by an ignore rule, which
  is why `init` checks rather than assumes.

## Scratch

- The `pi`, `claude` and `claude-work` wrappers export
  `TMPDIR=$(agent-notes tmp "$PPID")`, so an agent's temp files sit beside its
  notes under the repository it is working in.
- A user tmpfiles rule in `modules/programs/agent-notes.nix` ages out
  everything under `<state>/agents/tmp/<repo>/` untouched for three days, on the
  daily `systemd-tmpfiles-clean` run (Linux only). The repository directories
  themselves stay, so a checkout's `.agents/tmp` link never dangles. A session
  idle that long loses its old files too: there is no liveness check.
- On hosts that snapshot `/home`, `.local/state/agents/tmp` is a nested subvolume
  so scratch does not pin snapshots (`hosts/desktop/filesystems.nix`).

## Migration

`agent-notes migrate` reads the old layout, where every project was a bare name
under the data root, and reports before touching anything:

- A project whose name matches a checkout is mapped to that checkout's id; an
  ambiguous one takes `--map OLD=ID`. A checkout is found through its worktrees
  too, so one whose main checkout sits below a monorepo
  (`~/dev/devenv-tilt/projects/<name>`) still maps.
- Markdown moves as it is. A file that some note names moves to that topic's
  `files/`. Anything else is listed as unclaimed and, on `--apply`, deleted;
  `--keep-unclaimed` puts it under `_orphaned/<project>/unclaimed/` instead.
- A project that maps nowhere keeps its Markdown under `_orphaned/<project>/` and
  loses its unclaimed files the same way. Rerunning the migration picks such a
  project up once its checkout exists: the Markdown moves home and whatever was
  parked in its `unclaimed/` stays parked.
- Absolute and `~`-relative paths of every moved file are rewritten in the notes
  and in the agents' memory files. Relative links between notes keep working
  because a topic directory keeps its shape.
- Nothing is deleted until `--apply`, and `--apply` refuses when a destination
  already exists. Stop live sessions first: a note written through an old path
  during the run is not in the plan.

## Editing a note in the editor

- Zed shows the store through the link. `scan_symlinks` defaults to `expanded`,
  so the store's contents are indexed once the folder is expanded, and a note
  rewritten by an agent updates in place.
- `.agents/tmp` is in Zed's `file_scan_exclusions`: scratch is not worth the
  project search.
- `/open plan` in pi and Claude Code lists the store's notes, newest first, and
  opens the picked one in the editor. Ghostty opens a clicked `.agents/store` or
  store path there too. Both go through `agent-note-open` (`modules/scripts`).

## Traps

- Two checkouts of one upstream keep separate notes. That is deliberate: the
  identity is the checkout, not the remote.
- `git clean -xdf` removes the links; run `agent-notes init` to get them back.
  Nothing in the store is lost.
- `git worktree move` and a `mv` of the main checkout change the path the id
  hashes, so the old store stops being found.
- Btrfs snapshots of `/home` include the store. They are local recovery, not a
  backup; the store is not in any off-host backup.
