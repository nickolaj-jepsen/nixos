# Agent tooling

Read this before adding or changing a skill, a pi extension or package, pi itself, a Claude
Code mod or an agent language server. The hub daemon: `pkgs/agent-hub/README.md`. The plugins
and skills themselves: nickolaj-jepsen/agents' AGENTS.md and `docs/`.

## Rules that aren't in the code

- Skills are one registry, `fireproof.agents.skills`, filled from
  nickolaj-jepsen/agents (`lib.skills`) or from a feature leaf (gh-stack in
  `git.nix`, notes in `obsidian/agents.nix`). Private skills
  (Digital-Udvikling/skills) must not be flake inputs: they are marketplaces
  fetched at runtime, so only Claude Code gets them.
- In `pi/extensions/`, `core/` loads in every session and `parent/` only in the one you
  started. What parent features share is a service in `parent/services.ts`, never a module
  variable another feature imports.
- npm dependencies live in `extensions/package.json` and its lockfile, the npm root, never in
  `core/` or `parent/package.json` (`npm install --package-lock-only`).
- `pkgs/pi-packages/` and `pkgs/pi-coding-agent/` are pinned here rather than taken from
  nixpkgs, and each has an `UPDATERS` entry, so `just update-packages <name>` bumps it.
- `pi-work` is the same agent on a second profile: its own login, Copilot alone, its roles a
  copy with `model:` rewritten to `fireproof.dev.pi.work.fastModel`, and its MCP servers
  `fireproof.agents.workMcpServers`, shared with claude-work.
- `fireproof.agents.lspServers` is filled by `agent-lsp.nix`, one schema per leaf: Claude Code and
  Copilot CLI read it; pi doesn't.
- See what a mod or plugin draws, and its keys, in a real session before handing it back: load
  the `agent-plugin-dev` skill. A green `just build` says nothing about layout or focus.

## Agent tracing (Phoenix)

`fireproof.dev.phoenix.enable` opts in the trusted personal hosts (including
`work`, but excluding the shared `dev-ao`). The default personal and work
profiles send traces to separate projects (`claude-code`, `pi`, `claude-work`,
`pi-work`) on the same Phoenix server with the same key. Project names are
not access controls. Only send work metadata where your employer permits it.
Both personal and work profiles send content-bearing traces. Claude uses
Arize's `claude-code-tracing` plugin (`pkgs/claude-code-tracing`) — one AGENT
span per turn with the LLM calls and tool spans nested under it, and prompt,
tool argument and tool output capture on. A wrapper passes it with
`--plugin-dir` only when that profile owns the project and the key is
enrolled, so plain `claude`, `claude-work` and `claude-dev` each need nothing
beyond their own wrapper. The key's _path_ is what reaches the session; each
hook process reads the key itself, so no copy sits in the env a Bash tool can
read or in a file at rest. Pi uses the pinned `@amaster.ai/pi-telemetry`
extension with payload capture enabled, including model inputs/outputs and tool
data. It ignores project telemetry settings, reads its key from agenix, and
keeps credential masking and raw error-text suppression. `core/telemetry.ts`
loads it when the wrapper exports `PI_PHOENIX_TELEMETRY`, so subagent sessions
get it too; the patched build traces pi-subagents' in-process children as
`subagent [role]` spans under the tool call that spawned them, in the calling
trace. Neither agent ships logs or metrics. Trace content can include source
code, secrets printed by tools, and work data; it is stored on the homelab and
included in backups.

Upstream cuts no releases (only rc tags), so the plugin is pinned to a main
commit: bump `rev` and `hash` in `pkgs/claude-code-tracing/package.nix`
together, and re-read `tracing/claude_code/hooks/hooks.json` for the hook
events Claude Code now has. Claude's hook log is
`~/.arize/harness/logs/claude-code.log`; `ARIZE_VERBOSE=true` logs every fire
and `ARIZE_DRY_RUN=true` builds spans without sending them, both worth setting
for one session when traces don't show up.

To enroll a key, create a system API key in Phoenix Settings and run this from
Bash in the repo. Paste the key at the hidden prompt; don't put it on a command
line, in `.env`, or in settings JSON:

```bash
(
  set -o pipefail
  IFS= read -rs -p 'Phoenix API key: ' key && [ -n "$key" ] || exit 1
  printf '\n' >&2
  printf '%s\n' "$key" | just secret-write secrets/phoenix-client-key.age
)
just secret-rekey
```

Commit the encrypted source and rekeyed HM blobs before rolling out. Until the
source exists, the integration is inert. After enrollment, build and activate
one host first. Start fresh personal and work sessions, send a harmless prompt
in each, and exit. Check Phoenix for a Claude `Turn n` span tree and Pi
`chat-turn` spans in the corresponding projects. In Pi, `/telemetry status`
shows exporter status.
Verify that `just eval hm.fireproof.dev.phoenix.enable dev-ao` is `false`.
To revoke access, revoke the key in Phoenix, not just in Nix.

Enrolled hosts also install Arize's Phoenix CLI. Use `px project list` to
check the connection or `px trace list --project pi --limit 5` to inspect
recent traces. `px` (also `phoenix-cli`) defaults to the homelab and reads the
agenix key for that invocation only. Explicit endpoints, credentials or
profiles bypass this default. So do `px setup`, `px auth`, `px profile`, and
`px self`. The upstream `pxi` interactive CLI is installed but not configured.

## Traps

- The pi wrapper merges the leaf's `settings` and `mcp` into `~/.pi/agent/settings.json` and
  `mcp.json` at every launch (`~/.pi/work` for pi-work), so a key or server dropped from the
  leaf stays in the file until removed by hand. Only arrays are replaced.
- Every `core/` file and `parent/index.ts` evaluates its own copy of each module it imports,
  so module state is shared only among parent features. Don't pass state between `core/` and
  `parent/` through module variables or `globalThis`; read it from the session branch instead.
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
- A subagent is a session in this process, not a child process: it loads `settings.packages`
  minus `subagents.json`'s `excludedExtensionPackages`, never the launcher's `-e` paths. So an
  extension that must see children (telemetry) belongs in `core/`, and the parent and child
  instances do not share module state — jiti loads the file per session, so share through
  `globalThis` or the event bus.
- agent-hub already sees every pi and Claude Code session; don't add per-agent toast hooks.
- Nothing closes a worktree when a session or subagent ends, and `wt` doesn't look for
  processes in one: its only guard is the cwd it runs in. So agents land, close or drop theirs
  from the primary checkout (`agent-context.md`). Leaving with `action: "keep"`
  in either harness returns to the primary checkout without closing the worktree.
- Don't name an editor in the folder menus (pi `parent/chrome/places.ts`, Claude Code's
  `git-menu`): `fireproof.desktop.editor` picks it and `FIREPROOF_EDITOR` says which row
  leads. `editor-open` (`modules/scripts`) resolves it on PATH for shells and niri spawns, so
  a host with neither opens `nvim`; zed's CLI is `zeditor` on nixpkgs and `zed` from the cask,
  vscode's is `code` everywhere. Over ssh it asks the connection's own reverse forward first
  (`editor-open-bridge@`, `EDITOR_OPEN_*` in `modules/system/ssh.nix`), so the remote path
  opens locally, but only for the hosts in `bridgeHosts`: the editor would ssh on with this
  machine's keys, and the loopback port is reachable by any user on the remote.
