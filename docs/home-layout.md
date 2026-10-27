# Home layout

Every dev and desktop host has the same visible `~`, so nothing has to be
remembered per box, and config reads one declared layout instead of spelling
`~/dev` in a dozen places.

## The roots

The roots are `fireproof.paths` in `modules/base/fireproof.nix`, each with a
description of what it holds. Read them through `fpLib.homePath config "<root>"`
(absolute path) and `fpLib.homeRoots config` (every declared top-level name,
the XDG user dirs included); never write `~/dev` or `/home/<user>/…` in a leaf.

The visible top level is closed: the roots, the XDG user dirs (capitalised, as
apps and macOS expect), and on macOS the folders it creates itself. Anything
else is a stray. Dotfiles are out of scope.

What goes where:

- A repo you own or actively patch: `dev/<repo>`, flat. A clone you only read,
  a repro, or a fork you will throw away goes to scratch instead.
- Anything that is not a project: `scratch/<topic>/`. Dumps, experiments,
  reports, agent output that should outlive a session. Session temp stays in
  `/tmp/agent/<pid>` (docs/janitor.md).
- App data a service owns lives under XDG data, not at the top level: the LLM
  weights are in `~/.local/share/llm/models`.
- `nixos` is a root of its own, not a repo under `dev`.

On Linux the leaf `modules/base/home-layout.nix` sets `xdg.userDirs` with every
XDG name at its default and `projects` pointing at `dev`, and creates only the
dirs a host uses. On macOS the forced folders are tolerated as they are, and
screenshots go to `~/Pictures/Screenshots` like everywhere else.

## Agents

Agents may write anywhere in a declared root and in `/tmp`; a write to `~`
itself, to an undeclared top-level name or to a dotdir asks. Pi gets this as
`external_directory_write` roots, Claude Code as `additionalDirectories`.
Credentials are denied both ways in both.

Sessions in this repo (and its worktrees) may also write dotdirs, through the
committed `.claude/settings.json` and `.pi/extensions/pi-permission-system/config.json`.
Pi loads the latter only once the checkout is trusted, so each new worktree
asks for trust once.

## Strays and stale scratch

The janitor reads the layout from `~/.config/janitor/layout.json`, written by
its leaf. `janitor report` and the bar popout list:

- **Strays**: visible top-level entries outside the layout, each with where it
  probably belongs (a repo → `dev`, a renamed root → its new place, anything
  else → `scratch`). Never deleted or moved by the janitor.
- **Stale scratch**: scratch entries nothing inside has touched for 30 days,
  offered unticked. Only a tick deletes one, and apply re-checks the age.

## Moving a box onto the layout

By hand or by an agent, working down `janitor report`'s strays. Traps:

- **Close Obsidian before moving a vault.** LiveSync and the vault registry
  hold the old path; the Nix side already points at `notes/<vault>`.
- **Claude Code and pi key history on the path.** Moving a repo orphans
  `~/.claude/projects/<slug>` (and `~/.claude-work/…`), where the slug is the
  absolute path with `/` written as `-`. Rename the slug dir in the same step.
- **`llm-fetch` refetches** if the weights are not moved to the new data dir
  first.
- **A repo under `dev` that is really a reference clone** belongs in scratch;
  the janitor only sees that it is a repo.
