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
| Claude Code mod          | `claude-code/mods/<name>/` | `CLAUDE_CODE_PLUGIN_DIRS`     | `claude plugin validate`/`test` | `claude-dev`, `tsc -p`       |
| Two-harness plugin       | `agent-tools/plugins/`     | both rows above               | `pkgs.agent-tools`, then both   | `npm test` in `agent-tools/` |
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
  types; then `pi-dev`, from any directory, runs the checkout's `core` and
  `parent` in place of the installed ones without a rebuild
  (`fireproof.agents.checkout` says where the checkout is).
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
- Dev loop: `claude-dev`, from any directory, loads every mod from the checkout
  in place of the store copies, and a save reloads it with no switch. Only a
  change on the nix side (keybindings, settings, `userConfig` values) needs one.
- A change to what a mod draws or to its keys is seen before it is handed back:
  load the `claude-mod-dev` skill, which drives such a session in tmux and lists
  the engine's limits. A green `just build` says nothing about layout or focus.

## agent-tools

`agent-tools/` at the repo root holds the plugins both harnesses share, laid out to
be split into a repository of its own. A feature is one folder,
`agent-tools/plugins/<name>/`, which is itself the Claude Code plugin:

- `core/` is harness-free TypeScript: one file, no imports, no Node and no DOM, so
  Claude Code's hooks environment and pi both load it as it stands. Its tests are
  `core/*.spec.ts`, run by vitest (`npm test` in `agent-tools/`) and by
  `pkgs/agent-tools`, which every consumer builds from. `claude plugin test` runs
  only `*.test.ts(x)`, so the two never see each other's.
- `claude/` is the mod. `hooks/hooks.json` names `../claude/register.tsx`, so the
  plugin's root holds only that manifest, `.claude-plugin/` and `types/`.
- The pi half is still in `pi/extensions/parent/`, importing the core through a
  symlink (`parent/lib/answer`) that the pi leaf replaces with a copy at build time.
- No plugin imports the hub client. One that needs the hub is not a plugin.

`answer` is the first: `core/forms.ts` finds the question round or pick list a turn
ended on, steps a draft through it and writes the reply. Each harness holds the draft
in its session (the mod in `$.state`, pi on the session branch), so nothing is shared
between surfaces and nothing outlives the session but pi's branch entry.

Traps the engine sets for this layout, none of which `tsc` reports:

- The hooks module can't re-export `register` from another file: the engine reads
  `on(...)` calls from the file `hooks.json` names. Point `hooks.json` at the real
  module instead of writing a wrapper.
- `types/index.d.ts` must be self-contained, with no `import`. It restates the shapes
  `core/` owns; the module assigns the core's values to them, so `tsc -p` flags a drift.
- vitest takes the nearest `tsconfig.json`, and the plugin's extends types only
  `just dev-setup` lays. `core/tsconfig.json` is there to be nearer.

## Notes

- Every agent writes notes into the checkout's store, `.agents/store`, which is a
  symlink into `~/.local/share/agents/store/<repo-id>`. `agent-notes root --ensure`
  is the resolver, and `docs/notes.md` covers the identity, the git hook, scratch
  and the migration.
- A skill names its files relative to that store and never repeats where notes
  live: `agent-context.md` states the rule once, and the skills that write
  files (`annotate-plan`, `handoff`, `run-handoff`, `ideate`, `mine`, `onboard`,
  `tour`)
  only name their own layout.
- `/open plan` lists that store's Markdown, newest first, skipping `history/`,
  `files/` and dot directories, and opens the picked note in the editor. Each
  agent has its own small listing (pi `parent/chrome/notes.ts`, `git-menu`'s
  `hooks/notes.ts`); neither asks agent-hub.

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
- A plugin command's name can be refused at runtime and neither
  `claude plugin validate` nor `claude plugin test` says so:
  `$.command.register` throws for a name a built-in (`review`, now
  `/code-review`) or a skill (`tuicr`) already has, and the mod's own catch
  logs it at debug. Check a new name by typing it in a real session.
- agent-hub (`docs/agent-hub.md`) already sees every pi and Claude Code
  session; don't add per-agent toast hooks.
- Don't name an editor in the folder menus (pi `parent/chrome/places.ts`,
  Claude Code's `git-menu`, agent-hub's `menus.py`): `fireproof.desktop.editor`
  picks it. `editor-open` (`modules/scripts`) carries the argv for shells and
  niri spawns, and the `FIREPROOF_EDITOR` session variable tells the TUI menus
  which row leads. zed's CLI is `zeditor` on nixpkgs and `zed` from the cask;
  vscode's is `code` everywhere. `editor-open` resolves the editor on PATH, so a
  host with neither opens `nvim` instead of failing. Over ssh it asks the
  connection's own reverse forward first (SetEnv + RemoteForward in
  `modules/scripts`, answered by `editor-open-bridge@`), so the remote path opens
  in the local editor. That needs the remote's sshd to accept `EDITOR_OPEN_*`
  (`modules/system/ssh.nix`), and the bridge only answers for the hosts named in
  `bridgeHosts`, since the editor would ssh on with this machine's keys and the
  loopback port is reachable by any user on the remote; the caller falls back to
  nvim unless the bridge answers `ok`.
