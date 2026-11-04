# Agent tooling

Read this before adding or changing a skill, a pi extension or package, pi
itself, a Claude Code mod or an agent language server. pi's router, providers
and subagent roles are in `docs/models.md`; desktop toasts and the bar are in
`docs/agent-hub.md`.

## Where things go

Paths in the table that don't start with `skills/` or `pkgs/` are under
`modules/programs/`.

| Thing                    | Lives in                   | Registered by                 | Build check                     | Dev loop                     |
| ------------------------ | -------------------------- | ----------------------------- | ------------------------------- | ---------------------------- |
| Own skill                | `skills/<name>/`           | `agent-skills.nix`            | —                               | frontmatter check            |
| Third-party skill        | upstream source            | its feature leaf              | —                               | —                            |
| Private skill            | a Claude Code marketplace  | `claude-code/default.nix`     | —                               | —                            |
| Pi extension             | `pi/extensions/`           | `settings.packages`           | `tsc --noEmit`                  | `just dev-setup`, `pi -ne …` |
| Third-party pi package   | `pkgs/pi-packages/`        | `settings.packages`           | —                               | `UPDATERS` bump              |
| Pi itself                | `pkgs/pi-coding-agent/`    | the `pi` wrapper              | —                               | `UPDATERS` bump              |
| Pi settings, MCP servers | pi leaf `settings`, `mcp`  | the `pi` wrapper, at launch   | —                               | —                            |
| Claude Code mod          | `claude-code/mods/<name>/` | `CLAUDE_CODE_PLUGIN_DIRS`     | `claude plugin validate`/`test` | `just dev-setup`, `tsc -p`   |
| Language server          | `agent-lsp.nix`            | `fireproof.agents.lspServers` | —                               | —                            |

## Skills

- Own and third-party skills reach the agents through the
  `fireproof.agents.skills` registry (`attrsOf path`, merged across leaves).
- Own skills are `skills/<name>/SKILL.md` at the repo root, registered
  automatically by `modules/programs/agent-skills.nix`. They are publicly
  installable; see `skills/README.md`.
- A third-party skill is registered by its feature leaf from the upstream
  source, e.g. `modules/programs/git.nix` sets
  `fireproof.agents.skills.gh-stack = "${pkgs.unstable.gh-stack.src}/skills/gh-stack"`.
- Private skills (e.g. Digital-Udvikling/skills) must not be flake inputs.
  They are Claude Code plugin marketplaces fetched at runtime
  (`extraKnownMarketplaces`/`enabledPlugins` in
  `modules/programs/claude-code/default.nix`), so only Claude Code gets them.

## Pi

- `modules/programs/pi/extensions/` holds one local pi package per audience.
  The pi leaf builds both and lists them in `settings.packages`.
  - `core/` loads in every session, subagent children included. Each
    top-level `.ts` file is one extension (`"pi": {"extensions": ["./*.ts"]}`);
    a subfolder such as `memory/` holds its helpers.
  - `parent/` loads only in the session you started: the leaf names it in
    subagents.json's `excludedExtensionPackages`. A feature there is a default
    export that `parent/index.ts`, the package's one entry, calls. A feature
    that throws is reported and the rest still load.
  - What parent features share (user-wait, identity, editor decorators, …) is
    a service in `parent/services.ts`, passed as the second argument and built
    before any feature registers, never a module variable another feature
    imports.
  - `shared/` is not a package: it holds helpers both import. What one package
    writes and the other reads (session entries, `pi.events` payloads, tool
    names, the footer's tallies) is declared once in `shared/` with its
    parser.
  - A helper only one package needs lives in that package.
- The build runs `tsc --noEmit` over `core/`, `parent/` and `shared/` against
  the pi that ships, so a type error fails `just build`. That resolves
  `@earendil-works/pi-ai` to its published types, which no longer carry
  TypeBox's re-exports (pi's runtime width adds them back), so extension code
  imports `Type` from `typebox`, the copy pi aliases to the one it loads.
- npm dependencies go in `modules/programs/pi/extensions/package.json` and its
  lockfile, the npm root, never in `core/` or `parent/package.json`
  (`npm install --package-lock-only`; read via `importNpmLock`, no hash to
  bump).
- Dev loop: `just dev-setup` links `node_modules` into the folder for editor
  types; then this runs the tree without a rebuild:
  `pi -ne -e builtin:codemode -e builtin:mcp -e modules/programs/pi/extensions/core -e modules/programs/pi/extensions/parent`.
- `pkgs/pi-packages/` is one npm tree whose `package.json` holds the roster
  and the exact pins. The pi leaf lists each `$out/node_modules/<name>` as a
  local path in `settings.packages`, so pi loads them without running npm.
  Bumps go through `UPDATERS` (`pi-packages`), which rewrites the pins and
  regenerates the lock (read via `importNpmLock`, no hash to bump).
- `pkgs/pi-coding-agent/` pins the upstream release independently of nixpkgs:
  `release.json` holds the version plus the source, npm-lock and
  model-catalog hashes, and the build is nixpkgs'. Bumps go through `UPDATERS`
  (`pi-coding-agent`).
- The pi leaf wraps pi in its own `pi` script, which exports the env and
  merges the config. It places the rules in `~/.pi/agent/APPEND_SYSTEM.md` and
  the theme in `~/.pi/agent/themes/`.

## Claude Code mods

- A mod is a plugin folder with a hooks module in
  `modules/programs/claude-code/mods/<name>/`.
- The claude-code leaf builds it with `claude plugin validate` and
  `claude plugin test` against the claude-code that runs it, so an API break
  fails `just build`. It loads it through `CLAUDE_CODE_PLUGIN_DIRS` in the
  settings `env`.
- A new mod also gets an entry in `.claude-plugin/marketplace.json` and
  `modules/programs/claude-code/mods/README.md` to be publicly installable.

## Reviews

`/review` runs tuicr in the same terminal with the TUI suspended, so a review
is part of the session instead of a window beside it. Claude Code's `git-menu`
mod has the same command without the suspend: a picker pane and a Ghostty
window. Both write one claim per repository and hand the comments back as one
batch. The pi half is `parent/review/` (`review.ts` wires it; `types.ts` holds
what the two harnesses share: the session entry, the claim, the pinned scope,
the item and the batch text), and `git-menu`'s `hooks/review.ts` mirrors the
shared half.

- Bare `/review` re-attaches a live review, or opens the scope picker:
  uncommitted changes, the branch against `origin/HEAD`, the last commit,
  tuicr's own picker, every tracked file, a pull request, a custom revset. A
  commit range is resolved to hashes once, because a moved ref would be a
  different tuicr session.
- `inbox`, `send`, `take` and `kill` are subcommands. Any other argument goes
  to tuicr as argv, split without a shell, so quotes and spaces stay data;
  `-p`/`--path` is dropped because it only filters files within a session, and
  a command that is only `-p` is refused. Starting or attaching a review is
  refused while the agent streams; the subcommands still run.
- tuicr runs under `dtach -A <socket> -r winch -e ^G` at
  `$XDG_RUNTIME_DIR/pi-review/<sha256(root)[:16]>.sock`. `^G` is the way back
  to pi and every later hop is a client on the same pty, so marks survive;
  `q` is still tuicr's quit.
- A review dies with its pi session, which includes `/reload` and a session
  replacement: tuicr is asked to save through the socket, then the pid in its
  `active_sessions.json` is SIGTERMed. A review a crash left running is adopted
  by the next `/review`. The entry is on the session branch, so `/reload`
  brings the inbox and its border segment back.
- One claim per repository: `<agent dir>/review-claims/<sha256(root)[:16]>.json`,
  the same file from both harnesses. A live claim by another session makes
  `/review` say whose it is, and `/review take` rewrites it while keeping the
  ids already delivered. A claim is stale when its pid is gone or the agent-hub
  no longer lists its session; `at` is not a freshness signal, since Claude
  keeps its delivered watermark there.
- `/review send` puts every comment not yet delivered above the draft as one
  numbered list: a header naming the session slug and the repository, a pointer
  at the `tuicr` skill, then a location, type and body per comment. Comment
  text is data: nothing escapes it and its newlines stay. The submitted prompt
  that carries the batch's `tuicr review comments --session <slug>` line is
  what empties it from the inbox.
- The border reads `review 2 new · 5/7` while comments are pending and
  `review 5/7` after. `/review inbox` or a click opens the list; `j`/`k` move,
  `y` copies `path:line`, enter goes back into the review.
- While a review is live the agent-hub row says the session is asking, with
  `reviewing · 4 comments, 5/7 files`. The label is pushed before the TUI
  stops, because the review then holds pi's event loop.
- Unit tests are `parent/review/*.test.ts` (`npm test` in `extensions/`). The
  round trips are shell scenarios in `parent/review/scenario/`: `lib.sh` gives
  each a private tmux server, XDG tree, scratch agent dir and fixture
  repository, starts a real pi on it, and asserts on the captured pane, so a
  red run shows what the owner would have seen. They are not in `just check`;
  run `bash …/scenario/smoke.sh` and the one you touched.

## Language servers

- `fireproof.agents.lspServers` (`command`/`args`/`extensionToLanguage`) is
  filled by `modules/programs/agent-lsp.nix`. Each agent leaf maps it to its
  own schema.

## Traps

- `.claude-plugin/marketplace.json` discovers `skills/` by default; don't add
  a `skills` list there.
- No build check reads skill content. To check frontmatter, copy (don't
  symlink) `skills/` into `<dir>/skills/` and run
  `claude plugin validate --strict --json <dir>`; an empty `contents` is
  clean.
- Never add an npm package the pi leaf links in from pi itself or from
  `pkgs/pi-packages` (`@gotgenes/*`): an integration imports the package's
  published API instead of copying it (`mkExtensions` in
  `modules/programs/pi/default.nix`).
- Every `core/` file and `parent/index.ts` evaluates its own copy of each
  module it imports, so module state is shared only among parent features.
  Keep `shared/` and `core/lib/` stateless. State that has to outlive a module
  copy (across packages, children or reloads) goes through
  `shared/process-global.ts`, never a bare `globalThis`.
- The pi wrapper merges the leaf's `settings` and `mcp` into
  `~/.pi/agent/settings.json` and `mcp.json` at every launch, so a key or
  server dropped from the leaf stays in the file until removed by hand. Only
  arrays are replaced.
- `just dev-setup` links `modules/programs/pi/extensions/result`, and
  `node_modules` through it. The link is a GC root, but janitor `apply`
  removes a `result` link idle past 7 days; then in-repo `tsc` fails with
  `TS2688` for `node` and `pi -e` dev runs fail too. Re-run `just dev-setup`.
- A mod's build can't run `tsc`: the API types exist only once an
  interactive session loads the folder. `just dev-setup` runs one to lay them
  into each mod's gitignored `.claude-plugin/types/`, for the editor and
  `tsc -p <folder>`. Re-run it after a Claude Code upgrade.
- agent-hub (`docs/agent-hub.md`) already sees every pi and Claude Code
  session; don't add per-agent toast hooks.
