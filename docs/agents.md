# Agent tooling

Read this before adding or changing a skill, a pi extension or package, pi itself, a Claude
Code mod or an agent language server. The hub daemon: `pkgs/agent-hub/README.md`. The plugins
and skills themselves: nickolaj-jepsen/agents' AGENTS.md and `docs/`.

## Rules that aren't in the code

- Skills are one registry (`fireproof.agents.skills`, merged across leaves) that each leaf
  fills its own way: the input's `lib.skills`, a local one beside it (`plain` in
  `agent-skills.nix`) or from a feature leaf (`notes` in `obsidian/agents.nix`), a
  third-party one from its leaf's source. Private skills (Digital-Udvikling/skills) must not
  be flake inputs: they are marketplaces fetched at runtime, so only Claude Code gets them.
- In `pi/extensions/`, `core/` loads in every session and `parent/` only in the one you
  started. What parent features share is a service in `parent/services.ts`, never a module
  variable another feature imports. `shared/` is not a package: whatever one package writes
  and the other reads is declared there once, with its parser.
- chrome's prompt editor is the one payload that leaves this repo for a plugin:
  `parent/lib/editor-hooks.ts` offers its hooks on `pi.events`
  (`fireproof:editor-hooks:offer`, and again on `:request` for a package that loaded first),
  and spellfix's `pi/editor.ts` restates the channels and decorates with them.
- npm dependencies live in `extensions/package.json` and its lockfile, the npm root, never in
  `core/` or `parent/package.json` (`npm install --package-lock-only`).
- `pkgs/pi-packages/` and `pkgs/pi-coding-agent/` are pinned here rather than taken from
  nixpkgs, and each has an `UPDATERS` entry, so `just update-packages <name>` bumps it.
- `pi-work` is the same agent on a second profile: its own login, Copilot alone, its roles a
  copy with `model:` rewritten to `fireproof.dev.pi.work.fastModel`, and its MCP servers
  `fireproof.agents.workMcpServers`, shared with claude-work.
- `fireproof.agents.lspServers` is filled by `agent-lsp.nix`, one schema per leaf; pi's `lsp`
  plugin reads the JSON file `PI_LSP_SERVERS` names.
- See what a mod or plugin draws, and its keys, in a real session before handing it back: load
  the `agent-plugin-dev` skill. A green `just build` says nothing about layout or focus.
- A skill names its note files relative to the store and never says where notes live;
  `agent-context.md` states that once, and `docs/notes.md` has the rest.

## Traps

- The pi wrapper merges the leaf's `settings` and `mcp` into `~/.pi/agent/settings.json` and
  `mcp.json` at every launch (`~/.pi/work` for pi-work), so a key or server dropped from the
  leaf stays in the file until removed by hand. Only arrays are replaced.
- Every `core/` file and `parent/index.ts` evaluates its own copy of each module it imports,
  so module state is shared only among parent features. State that must outlive a module copy
  goes through `shared/process-global.ts`, never a bare `globalThis`.
- Never add an npm package the pi leaf links in from pi itself or from `pkgs/pi-packages`
  (`@gotgenes/*`): an integration imports the package's published API instead of copying it
  (`mkExtensions`).
- `just dev-setup` links `pi/extensions/result`, and `node_modules` through it, for editor
  types and in-repo `tsc`. The weekly `nh clean` removes a `result` link older than 7 days,
  after which `tsc` fails with `TS2688` and `pi -e` runs fail. Re-run `just dev-setup`.
- A mod's build can't run `tsc`: the API types exist only once an interactive session loads
  the folder. `just dev-setup` in agents runs one to lay them into each mod's gitignored
  `.claude-plugin/types/`; re-run it after a Claude Code upgrade.
- Claude Code shows a pi receipt as fixed text for its status and ignores `reason`, so pick
  the status by what that text says (`ReceiptStatus` in `parent/claude-peers/protocol.ts`).
- agent-hub already sees every pi and Claude Code session; don't add per-agent toast hooks.
- Nothing closes a worktree when a session or subagent ends, and `wt` doesn't look for
  processes in one: its only guard is the cwd it runs in. So agents land, close or drop theirs
  from the primary checkout (`agent-context.md`), and only explicit leaves close one
  (`ExitWorktree` with `remove`, `exit_worktree` and `/back`, `wt land`).
- Don't name an editor in the folder menus (pi `parent/chrome/places.ts`, Claude Code's
  `git-menu`): `fireproof.desktop.editor` picks it and `FIREPROOF_EDITOR` says which row
  leads. `editor-open` (`modules/scripts`) resolves it on PATH for shells and niri spawns, so
  a host with neither opens `nvim`; zed's CLI is `zeditor` on nixpkgs and `zed` from the cask,
  vscode's is `code` everywhere. Over ssh it asks the connection's own reverse forward first
  (`editor-open-bridge@`, `EDITOR_OPEN_*` in `modules/system/ssh.nix`), so the remote path
  opens locally, but only for the hosts in `bridgeHosts`: the editor would ssh on with this
  machine's keys, and the loopback port is reachable by any user on the remote.
