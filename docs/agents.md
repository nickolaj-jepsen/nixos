# Agent tooling

Read this before adding or changing a skill, a pi extension or package, pi
itself, a Claude Code mod or an agent language server. pi's providers, models
and subagent roles: `docs/models.md`; desktop toasts and the bar:
`docs/agent-hub.md`.

## Where things go

Paths in the table that don't start with `agents:` or `pkgs/` are under
`modules/programs/`.

| Thing                    | Lives in                    | Registered by                 | Build check                     | Dev loop                     |
| ------------------------ | --------------------------- | ----------------------------- | ------------------------------- | ---------------------------- |
| Own skill                | `agents:skills/<name>/`     | `agent-skills.nix`            | —                               | frontmatter check            |
| Third-party skill        | upstream source             | its feature leaf              | —                               | —                            |
| Private skill            | a Claude Code marketplace   | `claude-code/default.nix`     | —                               | —                            |
| Pi extension             | `pi/extensions/`            | `settings.packages`           | `tsc --noEmit`                  | `just dev-setup`, `pi -ne …` |
| A plugin's pi half       | `agents:plugins/<name>/pi/` | the plugin's `package.json`   | `pkgs.agent-tools` (agents)     | `just dev-setup`, `pi -ne …` |
| Third-party pi package   | `pkgs/pi-packages/`         | `settings.packages`           | —                               | `UPDATERS` bump              |
| Pi itself                | `pkgs/pi-coding-agent/`     | the `pi` wrapper              | —                               | `UPDATERS` bump              |
| Pi settings, MCP servers | pi leaf `settings`, `mcp`   | the `pi` wrapper, at launch   | —                               | —                            |
| Claude Code mod          | `agents:plugins/<name>/`    | `CLAUDE_CODE_PLUGIN_DIRS`     | `claude plugin validate`/`test` | `claude-dev`, `tsc -p`       |
| Two-harness plugin       | `agents:plugins/`           | both rows above               | `pkgs.agent-tools`, then both   | `just test` in agents        |
| Language server          | `agent-lsp.nix`             | `fireproof.agents.lspServers` | —                               | —                            |

## Skills

- Skills reach the agents through the `fireproof.agents.skills` registry
  (`attrsOf path`, merged across leaves).
- Own skills are `skills/<name>/SKILL.md` in nickolaj-jepsen/agents, registered
  automatically by `agent-skills.nix` (the input's `lib.skills`). They are
  publicly installable; a new one gets a line in that repo's README.md Skills
  section.
- A personal skill that shouldn't be public lives in this repo and is added to
  the registry beside `lib.skills` (`plain` in `agent-skills.nix`) or by its
  feature leaf (`notes` in `obsidian/agents.nix`).
- A third-party skill is registered by its feature leaf, from the upstream
  source (see `gh-stack` in `git.nix`).
- Private skills (e.g. Digital-Udvikling/skills) must not be flake inputs: they
  are Claude Code plugin marketplaces fetched at runtime
  (`extraKnownMarketplaces`/`enabledPlugins` in `claude-code/default.nix`), so
  only Claude Code gets them.

## Pi

- `modules/programs/pi/extensions/` holds one local pi package per audience.
  The pi leaf builds both and lists them in `settings.packages`.
  - `core/` loads in every session, subagent children included. Each
    top-level `.ts` file is one extension; a subfolder such as `lib/` holds
    its helpers.
  - `parent/` loads only in the session you started (the leaf names it in
    subagents.json's `excludedExtensionPackages`). A feature is a default
    export that `parent/index.ts`, the package's one entry, calls; one that
    throws is reported and the rest still load.
  - What parent features share is a service in `parent/services.ts`, passed as
    the second argument and built before any feature registers, never a module
    variable another feature imports.
  - `shared/` is not a package: it holds helpers both import. What one package
    writes and the other reads (session entries, `pi.events` payloads, tool
    names) is declared once there, with its parser.
  - A helper only one package needs lives in that package.
  - A plugin's pi half (`agents:plugins/<name>/pi/`) is a package of its own,
    named under `pi` in the plugin's `package.json`
    (`"agentTools": {"subagents": true}` there also loads it in subagents).
    It imports the plugin's `core/` directly, gets no copy under `parent/lib/`
    and can't import `shared/`. A plugin can be pi-only.
  - The one payload that leaves this repo for a plugin is chrome's prompt
    editor: `parent/lib/editor-hooks.ts` offers its hooks on `pi.events`
    (`fireproof:editor-hooks:offer`, and again on `:request` for a package that
    loaded first), and spellfix's `pi/editor.ts` restates the channels and
    decorates with them. Only spellfix's underline and live recheck need it; its
    commands, shortcut and review fall back to `ctx.ui.getEditorText()`.
- The build runs `tsc --noEmit` over `core/`, `parent/` and `shared/` against
  the shipped pi, so a type error fails `just build`; `pkgs.agent-tools` does
  the same for the plugins' `pi/` halves. `@earendil-works/pi-ai`'s published
  types carry no TypeBox re-exports (pi adds them at runtime), so import `Type`
  from `typebox`, the copy pi aliases to the one it loads.
- npm dependencies go in `extensions/package.json` and its lockfile, the npm
  root, never in `core/` or `parent/package.json`
  (`npm install --package-lock-only`; read via `importNpmLock`, no hash to
  bump).
- Dev loop: `just dev-setup` links `node_modules` for editor types; `pi-dev`,
  from any directory, then runs the checkout's `core` and `parent` in place of
  the installed ones, no rebuild (`fireproof.agents.checkout` says where).
- `pkgs/pi-packages/` is one npm tree: `package.json` holds the roster and the
  exact pins, and the pi leaf lists each `$out/node_modules/<name>` as a local
  path in `settings.packages`, so pi loads them without running npm.
  `UPDATERS` (`pi-packages`) rewrites the pins and regenerates the lock.
- `pkgs/pi-coding-agent/` pins the upstream release independently of nixpkgs:
  `release.json` holds the version plus the source, npm-lock and model-catalog
  hashes, and the build is nixpkgs'. `UPDATERS` (`pi-coding-agent`) bumps it.
- The leaf's `pi` wrapper exports the env, merges the config, and places the
  rules in `~/.pi/agent/APPEND_SYSTEM.md` and the theme in
  `~/.pi/agent/themes/`.
- `pi-work` is the same agent on a second profile: `PI_CODING_AGENT_DIR=~/.pi/work`,
  its own login, and GitHub Copilot as its only provider. Rules, keybindings,
  theme, permission policy and extensions are symlinks into `~/.pi/agent`, so
  one edit reaches both; models, credentials, sessions and MCP servers are its
  own. Its roles are a copy of the same files with `model:` rewritten to
  `fireproof.dev.pi.work.fastModel`. It gets `fireproof.agents.workMcpServers`,
  shared with claude-work, and not the DeepSeek router (docs/models.md).

## Claude Code mods

- A mod is a plugin of nickolaj-jepsen/agents with a hooks module, its code in
  `plugins/<name>/claude/`, built by `mkToolMod` (the input's
  `lib.mkClaudePlugin`) for every plugin folder with a
  `.claude-plugin/plugin.json`; `loadFirst` sets the load order of the first few.
- The build runs `claude plugin validate` and `claude plugin test` against the
  claude-code that runs it, so an API break fails `just build`. Mods load
  through `CLAUDE_CODE_PLUGIN_DIRS` in the settings `env`.
- A new mod also needs an entry in agents' `.claude-plugin/marketplace.json`
  (its `nix flake check` compares it to the folders) and a section in its
  README.md.
- Dev loop: `claude-dev`, from any directory, loads every mod from the agents
  checkout (`fireproof.agents.devCheckout`) in place of the store copies, and a
  save reloads it with no switch. Only a nix-side change (keybindings,
  settings, `userConfig` values) needs one.
- See what a mod draws, and its keys, in a real session before handing it
  back: load the `agent-plugin-dev` skill. A green `just build` says nothing
  about layout or focus.

## agents

nickolaj-jepsen/agents is a flake input: `overlays.default` supplies
`pkgs.agent-tools`, checked against `pkgs/pi-coding-agent` here (each Claude
plugin against `pkgs/claude-code`), and `lib.skills` and `lib.plugins` feed the
leaves. Its README.md covers every plugin: layout, traps, demo recordings.

## Notes

- Every agent writes notes into the checkout's store, `.agents/store`, a
  symlink into `~/.local/share/agents/store/<repo-id>`; `agent-notes root --ensure`
  resolves it. See `docs/notes.md`.
- A skill names its files relative to the store and never says where notes
  live; `agent-context.md` states that once.
- `/open plan` lists the store's Markdown, newest first, skipping `history/`,
  `files/` and dot directories. Each agent has its own listing (pi
  `parent/chrome/notes.ts`, `git-menu`'s `claude/notes.ts`), not agent-hub's.

## Language servers

- `fireproof.agents.lspServers` is filled by `agent-lsp.nix`; each agent leaf
  maps it to its own schema. pi's is the `lsp` plugin (`plugins/lsp/pi/` of
  agents), which reads the JSON file `PI_LSP_SERVERS` names, written by the pi
  leaf.

## Traps

- No build check reads skill content. To check frontmatter, copy (don't
  symlink) `skills/` of agents into `<dir>/skills/` and run
  `claude plugin validate --strict --json <dir>`; an empty `contents` is
  clean.
- Never add an npm package the pi leaf links in from pi itself or from
  `pkgs/pi-packages` (`@gotgenes/*`): an integration imports the package's
  published API instead of copying it (`mkExtensions` in
  `modules/programs/pi/default.nix`).
- Every `core/` file and `parent/index.ts` evaluates its own copy of each
  module it imports, so module state is shared only among parent features.
  Keep `shared/` and `core/lib/` stateless; state that must outlive a module
  copy (across packages, children or reloads) goes through
  `shared/process-global.ts`, never a bare `globalThis`.
- The pi wrapper merges the leaf's `settings` and `mcp` into
  `~/.pi/agent/settings.json` and `mcp.json` at every launch (`~/.pi/work` for
  pi-work), so a key or server dropped from the leaf stays in the file until
  removed by hand. Only arrays are replaced.
- `just dev-setup` links `modules/programs/pi/extensions/result`, and
  `node_modules` through it. The weekly `nh clean` removes a `result` link
  older than 7 days; then in-repo `tsc` fails with `TS2688` for `node` and
  `pi -e` dev runs fail. Re-run `just dev-setup`.
- A mod's build can't run `tsc`: the API types exist only once an interactive
  session loads the folder. `just dev-setup` in agents runs one to lay them
  into each mod's gitignored `.claude-plugin/types/`, for the editor and
  `tsc -p <plugin>/claude`; re-run it after a Claude Code upgrade.
- A plugin command's name can be refused at runtime with neither
  `claude plugin validate` nor `claude plugin test` saying so:
  `$.command.register` throws for a name a built-in or a skill already has
  (`/code-review`, `tuicr`), and the mod's own catch logs it at debug. Check a
  new name by typing it in a real session.
- Claude Code shows a pi receipt as fixed text for its status and ignores
  `reason`, so pick the status by what that text says (`ReceiptStatus` in
  `parent/claude-peers/protocol.ts`).
- agent-hub (`docs/agent-hub.md`) already sees every pi and Claude Code
  session; don't add per-agent toast hooks.
- Nothing closes a worktree when a Claude Code or pi session or subagent ends:
  a folder an agent's Bash calls only visit would vanish mid-task. Only
  explicit leaves close one (`ExitWorktree` with `remove`, pi's
  `exit_worktree` and `/back`, `wt land`); `wt clean` sweeps the rest. `wt`
  doesn't look for processes in a worktree; its only guard is the cwd it runs
  in, so agents land, close or drop theirs from the primary checkout
  (`agent-context.md`), and the `WorktreeRemove` hook and `/back` run
  `wt close` from `/`.
- Don't name an editor in the folder menus (pi `parent/chrome/places.ts`,
  Claude Code's `git-menu`): `fireproof.desktop.editor` picks it. `editor-open`
  (`modules/scripts`) carries the argv for shells and niri spawns, and
  `FIREPROOF_EDITOR` tells the TUI menus which row leads. zed's CLI is
  `zeditor` on nixpkgs and `zed` from the cask; vscode's is `code` everywhere.
  `editor-open` resolves the editor on PATH, so a host with neither opens
  `nvim`. Over ssh it first asks the connection's own reverse forward (SetEnv
  - RemoteForward in `modules/scripts`, answered by `editor-open-bridge@`), so
    the remote path opens in the local editor. That needs the remote's sshd to
    accept `EDITOR_OPEN_*` (`modules/system/ssh.nix`); the bridge answers only
    for the hosts in `bridgeHosts`, since the editor would ssh on with this
    machine's keys and the loopback port is reachable by any user on the remote.
    The caller falls back to nvim unless the bridge answers `ok`.
