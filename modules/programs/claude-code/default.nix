# Always-on; the claude-work wrapper is gated by claude-code.work.enable.
{fpLib, ...}: {
  flake.modules.homeManager.claude-code = {
    pkgs,
    config,
    lib,
    ...
  }: let
    cfg = config.fireproof.claude-code;
    ccfg = config.programs.claude-code;
    hmLib = config.lib;
    homeDir = config.home.homeDirectory;
    phoenix = import ../_phoenix-client.nix {inherit config;};

    # Surfaces session state that settings.json can't pin (model, effort as
    # changed by /effort, fast mode), git state and the last response's
    # throughput, plus which profile is running — claude-work shares this
    # file and CLAUDE.md by symlink, so nothing else distinguishes the two.
    # ANSI codes only, so the terminal's Flexoki palette stays authoritative.
    statusLine = pkgs.writeShellApplication {
      name = "claude-statusline";
      runtimeInputs = [pkgs.jq pkgs.git pkgs.gh pkgs.coreutils];
      text = builtins.readFile ./statusline.sh;
    };

    # Loads the cwd's direnv/nix-direnv env into the Bash tool, which otherwise
    # keeps the env of the shell claude was launched from.
    direnvHook = pkgs.writeShellApplication {
      name = "claude-direnv";
      runtimeInputs = [config.programs.direnv.package];
      text = ''
        [ -n "''${CLAUDE_ENV_FILE:-}" ] || exit 0
        # A blocked or missing .envrc exports nothing; don't surface it as a hook error on every cd.
        direnv export bash >>"$CLAUDE_ENV_FILE" 2>/dev/null || true
      '';
    };

    direnvHooks = [
      {
        hooks = [
          {
            type = "command";
            command = lib.getExe direnvHook;
          }
        ];
      }
    ];

    skillGuard = pkgs.writeShellApplication {
      name = "claude-skill-guard";
      runtimeInputs = [pkgs.jq pkgs.gnugrep];
      runtimeEnv.LOCAL_SKILLS = pkgs.writeText "claude-local-skills" (lib.concatLines skillNames);
      text = builtins.readFile ./skill-guard.sh;
    };

    # Claude Code's own worktrees (EnterWorktree, `claude -w`, agent isolation)
    # are made by `wt new` and closed by `wt close` when removed explicitly; a
    # session that ends leaves them for `wt clean`. Without the remove half Claude falls back to
    # `git worktree remove --force`, which would discard uncommitted work.
    worktreeHooks = pkgs.writeShellApplication {
      name = "claude-worktree-hooks";
      runtimeInputs = [pkgs.jq pkgs.coreutils];
      text = builtins.readFile ./worktree-hooks.sh;
    };
    worktreeLifecycle = [
      {
        hooks = [
          {
            type = "command";
            command = lib.getExe worktreeHooks;
          }
        ];
      }
    ];

    # claude-code resolves the checker off PATH by bare name, so it has to be a
    # real package rather than a store path like the LSP servers. hunspell
    # over aspell because only it takes several dictionaries at once (`-d a,b`).
    dictionaries = fpLib.hunspellLanguages;
    spellChecker = fpLib.mkHunspell pkgs;
    # Mutable: the spellfix picker adds words to it. hunspell neither creates a
    # missing personal dictionary nor saves into one, so activation touches it.
    personalDictionary = fpLib.hunspellPersonalDictionary config;

    # A plugin of nickolaj-jepsen/agents as this generation pins it, Claude half only: the
    # build validates and tests it against the claude-code that runs it, so a bump that breaks
    # its API (or drops the keybinding action spellfix borrows) fails the switch. A published
    # snapshot is validated the same way, against the same package (agent-skills.nix).
    baselinePlugins = config.fireproof.agents.updates.baseline.plugins;
    # Every plugin of agents with a Claude half. linear-issue's button is spliced into the
    # built-in you-should-know card by label; a card redesign only hides it, with a toast.
    claudePlugins = lib.attrNames (lib.filterAttrs (_: plugin: plugin.claude != null) baselinePlugins);
    mods = lib.genAttrs claudePlugins (name: baselinePlugins.${name}.claude);
    # The band stacks each mod's row in load order: answer's offer first, spellfix's band
    # button next, then the rest by name.
    loadFirst = ["answer" "spellfix"];
    loadOrder = loadFirst ++ lib.subtractLists loadFirst claudePlugins;
    # ctrl+q presses spellfix's band button, borrowing an action; a single modified key
    # reaches a plugin Button only from the Global context.
    keybindings = {
      "$schema" = "https://www.schemastore.org/claude-code-keybindings.json";
      bindings = [
        {
          context = "Global";
          bindings."ctrl+q" = "app:toggleDiffNoiseFilter";
        }
        {
          # A mod can't take the keyboard, so this hands it to the band, where answer's form
          # is (plugins/answer in agents): its row first, and Enter opens it.
          context = "Chat";
          bindings."alt+a" = "abovePrompt:focus";
        }
        {
          context = "AbovePrompt";
          bindings = {
            "j" = "abovePrompt:next";
            "k" = "abovePrompt:previous";
          };
        }
        {
          # Escape in a band field steps back onto the form, not out to the prompt; a
          # second one, from a button, leaves.
          context = "AbovePromptInput";
          bindings."escape" = "abovePrompt:previous";
        }
      ];
    };

    # Only the profile that owns the project, and only once a key is enrolled.
    tracingArgs = {
      project,
      profileCheck,
    }: ''
      tracing_args=()
      ${lib.optionalString phoenix.enabled ''
        ${phoenix.clear}
        if [ -s ${lib.escapeShellArg phoenix.path} ] && ${profileCheck}; then
          export PHOENIX_ENDPOINT=${lib.escapeShellArg phoenix.baseUrl}
          export PHOENIX_PROJECT=${lib.escapeShellArg project}
          export CLAUDE_TRACING_KEY_FILE=${lib.escapeShellArg phoenix.path}
          export ARIZE_LOG_PROMPTS=true ARIZE_LOG_TOOL_DETAILS=true ARIZE_LOG_TOOL_CONTENT=true
          tracing_args=(--plugin-dir ${pkgs.claude-code-tracing})
        fi
      ''}
    '';

    # fireproof.agents.updates: what a publication changes is resolved at launch, because
    # Claude Code reads its plugin dirs from settings once per session. Neither the checkout
    # nor a build at startup is involved; an update reaches the next session only.
    updates = config.fireproof.agents.updates;
    skillNames = lib.attrNames config.fireproof.agents.skills;

    # The env block every session starts from. The launch settings repeat all of it with the
    # effective plugin dirs, so nothing depends on how a partial env map would merge.
    settingsEnv = {
      # Not programs.claude-code.plugins: the env block also reaches desktop-app sessions.
      CLAUDE_CODE_PLUGIN_DIRS = lib.concatMapStringsSep ":" (name: "${mods.${name}}") loadOrder;
      # hunspell's personal dictionary for the underline's checker too.
      WORDLIST = personalDictionary;
    };
    settingsEnvJson = jsonFormat.generate "claude-agent-env.json" {env = settingsEnv;};

    # Resolves the published paths, syncs this profile's skill view and writes the launch
    # settings; prints that file, so a launcher has one --settings to pass.
    agentSettings = pkgs.writeShellApplication {
      name = "claude-agents-settings";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        ${updates.envExports}
        export AGENTS_HARNESS=claude
        export AGENTS_PROFILE="''${CLAUDE_CONFIG_DIR:-${ccfg.configDir}}"
        export AGENTS_CLAUDE_SETTINGS_DIR="${config.xdg.stateHome}/agents-updates/claude-settings"
        export AGENTS_CLAUDE_ENV=${settingsEnvJson}
        export AGENTS_PLUGIN_ORDER=${lib.escapeShellArg (lib.concatStringsSep " " loadOrder)}
        exec ${lib.getExe updates.helper}
      '';
    };

    # `claude --settings` merges over the user's settings, so only what changes is passed:
    # the effective plugin dirs. The pinned
    # dirs stay in settings.json for anything that does not go through this launcher.
    launchSettings = ''
      settings_args=()
      ${lib.optionalString updates.enable ''
        if agents_settings=$(${lib.getExe agentSettings} 2>/dev/null); then
          settings_args=(--settings "$agents_settings")
        else
          # No resolved settings file: keep the session usable.
          echo "agents updates: could not resolve the published paths; the pinned ones load" >&2
        fi
      ''}
    '';

    # Claude Code resolves plugin paths and skills at startup and needs a restart to see new
    # ones: the SessionStart hook reports what is published, it never claims a reload.
    agentCheck = pkgs.writeShellApplication {
      name = "claude-agents-check";
      runtimeInputs = [pkgs.jq];
      text = ''
        ${updates.envExports}
        out=$(${lib.getExe updates.cli} check 2>/dev/null) || out=""
        [ -z "$out" ] || ${lib.getExe pkgs.jq} -n --arg m "$out" '{systemMessage: $m}'
      '';
    };

    # `claude plugin test` refuses any option before `plugin`, and the
    # home-manager wrapper always prepends --plugin-dir.
    claudeEntry = pkgs.writeShellScript "claude" ''
      if [ "''${1:-}" = plugin ]; then exec -a "$0" ${lib.getExe ccfg.package} "$@"; fi
      ${launchSettings}
      ${tracingArgs {
        project = "claude-code";
        profileCheck = ''[ -z "''${CLAUDE_CONFIG_DIR:-}" ]'';
      }}
      exec -a "$0" ${ccfg.finalPackage}/bin/claude "''${settings_args[@]}" "''${tracing_args[@]}" "$@"
    '';

    # Work-owned MCP servers ride in their own plugin, which only claude-work
    # passes to the wrapper: the shared programs.mcp registry reaches every agent.
    jsonFormat = pkgs.formats.json {};
    workMcpJson = jsonFormat.generate "claude-work-mcp.json" {
      mcpServers = lib.mapAttrs (name: server:
        hmLib.mcp.transformMcpServer {
          inherit server;
          extraTransforms = [hmLib.mcp.addType (hmLib.mcp.wrapEnvFilesCommand {inherit pkgs name;})];
        })
      config.fireproof.agents.workMcpServers;
    };
    workMcpPlugin = pkgs.runCommand "claude-code-work-mcp" {} ''
      install -Dm644 ${workMcpJson} $out/.mcp.json
      install -Dm644 ${jsonFormat.generate "claude-work-mcp-plugin.json" {name = "claude-work-mcp";}} $out/.claude-plugin/plugin.json
    '';
    workMcpArgs = lib.optionals (config.fireproof.agents.workMcpServers != {}) ["--plugin-dir" workMcpPlugin];

    claudeWorkWrapper = pkgs.writeShellApplication {
      name = "claude-work";
      runtimeInputs = [config.programs.claude-code.finalPackage];
      text = ''
        ${phoenix.clear}
        export CLAUDE_CONFIG_DIR="''${CLAUDE_CONFIG_DIR:-$HOME/.claude-work}"
        mkdir -p "$CLAUDE_CONFIG_DIR"
        ${launchSettings}
        ${tracingArgs {
          project = "claude-work";
          profileCheck = ''[ "$CLAUDE_CONFIG_DIR" = "$HOME/.claude-work" ]'';
        }}
        exec ${ccfg.finalPackage}/bin/claude "''${settings_args[@]}" ${lib.escapeShellArgs workMcpArgs} "''${tracing_args[@]}" "$@"
      '';
    };

    # Every config surface home-manager generates under ~/.claude, derived from the
    # options rather than hand-listed: a surface added below (agents, rules, hooks,
    # output-styles) would otherwise silently never reach the work profile.
    # `plugins` and `sessions` are shared mutable state, so they are always
    # mirrored; one session registry lets both profiles' sessions see each other
    # as peers and reach agent-hub. settings.json and keybindings.json are not:
    # Claude writes them, so each profile gets its own writable copy (below).
    mirroredNames =
      ["CLAUDE.md" "plugins" "sessions"]
      ++ lib.optional (skillNames != []) "skills"
      ++ lib.optional (ccfg.outputStyles != {}) "output-styles"
      ++ lib.concatMap (name: lib.optional (ccfg.${name} != {} || ccfg."${name}Dir" != null) name)
      ["agents" "commands" "hooks" "rules"];

    workFiles = lib.mkIf cfg.work.enable (lib.listToAttrs (map (name:
      lib.nameValuePair ".claude-work/${name}" {
        source = hmLib.file.mkOutOfStoreSymlink "${homeDir}/.claude/${name}";
      })
    mirroredNames));
  in {
    # .claude-plugin/marketplace.json lives in agents, whose checks compare it to the plugin folders.

    # Mutes warning about installMethod by placing the wrapped binary in ~/.local/bin
    home.file = lib.mkMerge [
      {
        ".local/bin/claude".source = claudeEntry;
        # Bindings live in `keybindings` above.
        ".claude/keybindings.json".text = builtins.toJSON keybindings;
      }
      (lib.mkIf cfg.work.enable {
        ".claude-work/settings.json".source = config.home.file."${ccfg.configDir}/settings.json".source;
        ".claude-work/keybindings.json".source = config.home.file.".claude/keybindings.json".source;
      })
      workFiles
    ];

    # Writable for /config, /model and "always allow", reset to Nix's on activation
    # (modules/base/writable-configs.nix). A real file in ~/.claude also keeps Claude
    # Code's watch on settings.json's parent dir off /nix/store.
    fireproof.writableConfigs = lib.mkMerge [
      {
        claude-settings.file = "${ccfg.configDir}/settings.json";
        claude-keybindings.file = ".claude/keybindings.json";
      }
      (lib.mkIf cfg.work.enable {
        claude-work-settings.file = ".claude-work/settings.json";
        claude-work-keybindings.file = ".claude-work/keybindings.json";
      })
    ];

    # fireproof.agents.updates owns the per-name entries of ${ccfg.configDir}/skills: the
    # launch and this activation point them at the effective store paths, and the helper
    # replaces a previous generation's entry (home-manager's directory of store links, or the
    # checkout links `agents.live` made) only when it holds nothing but those. The directory
    # itself stays a real directory: Claude Code also syncs skills of its own into it.
    # A publication reaches the next start; a running session keeps what it loaded.
    home.activation.agentsSkills = lib.mkIf updates.enable (lib.hm.dag.entryAfter ["linkGeneration"] ''
      run ${lib.getExe agentSettings} >/dev/null || echo "agents updates: could not refresh claude's skill view" >&2
    '');

    home.activation.hunspellPersonalDictionary = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run mkdir -p ${lib.escapeShellArg (dirOf personalDictionary)}
      [ -e ${lib.escapeShellArg personalDictionary} ] || run touch ${lib.escapeShellArg personalDictionary}
    '';

    home.packages = [spellChecker] ++ lib.optional cfg.work.enable claudeWorkWrapper;

    programs.claude-code.context = builtins.readFile ../agent-context.md;

    programs.claude-code = {
      enable = true;
      package = pkgs.claude-code;
      enableMcpIntegration = true;
      # With updates on, the skills come from the synced view (home.file above); the registry
      # is home-manager's own set of store links only when nothing is syncing it.
      skills = lib.optionalAttrs (! updates.enable) config.fireproof.agents.skills;

      # The fireproof.agents.lspServers registry (agent-lsp.nix); its rust-analyzer
      # replaces the hand-installed rust-analyzer-lsp plugin.
      lspServers = config.fireproof.agents.lspServers;

      settings = {
        tui = "fullscreen";
        voice.enabled = true;
        useAutoModeDuringPlan = true;
        skipAutoPermissionPrompt = true;
        # Transcripts are training/eval data for the pi auto-gate judge; the
        # default prunes them after 30 days.
        cleanupPeriodDays = 3650;
        # Drives niri's urgency hint; the bar's dots come from agent-hub.
        preferredNotifChannel = "terminal_bell";
        # /effort saves per model under modelSettings, but settings.json is a
        # read-only store symlink, so those picks only last the session. Keys are
        # aliases, resolved like /model, so they follow new model releases; the
        # top-level level is the legacy default for models not listed.
        effortLevel = "high";
        # No pin means the account default applies, which has drifted to Sonnet.
        model = "opus";
        modelSettings = {
          opus.effortLevel = "high";
          fable.effortLevel = "xhigh";
          sonnet.effortLevel = "medium";
        };
        hooks = let
          hub = config.fireproof.dev.agent-hub.enable;
          # Fire and forget: the hub reads the rest of the session on its own time.
          hubHook = [
            {
              hooks = [
                {
                  type = "command";
                  command = "${lib.getExe pkgs.agent-hub} hook";
                  async = true;
                }
              ];
            }
          ];
        in
          {
            SessionStart =
              direnvHooks
              ++ lib.optional updates.enable {
                hooks = [
                  {
                    type = "command";
                    command = lib.getExe agentCheck;
                  }
                ];
              };
            CwdChanged = direnvHooks;
            WorktreeCreate = worktreeLifecycle;
            WorktreeRemove = worktreeLifecycle;
            PreToolUse = [
              {
                matcher = "Skill";
                hooks = [
                  {
                    type = "command";
                    command = lib.getExe skillGuard;
                  }
                ];
              }
            ];
          }
          # Only a turn's start and its two endings: the closing words and tasks still out come with Stop,
          # the API error with StopFailure.
          // lib.optionalAttrs hub {
            UserPromptSubmit = hubHook;
            Stop = hubHook;
            StopFailure = hubHook;
          };
        # Context for the auto-mode classifier, adapted from /auto-mode-setup
        # (run per-project) to every project and host. Replaces the built-in
        # environment wholesale, like the setup's own output: no "$defaults".
        autoMode.environment = let
          work = config.fireproof.work.enable;
          onWork = lib.optional work;
        in
          [
            "### Org-wide"
            (
              if work
              then "- **Organization**: Digital-Udvikling (GitHub org of the user's employer) for work repos; everything else is personal"
              else "- **Organization**: None configured (personal machine)"
            )
            "- **Cloud provider(s)**: None configured"
            "- **Repository visibility**: github.com/nickolaj-jepsen/nixos (~/nixos) is PUBLIC; a push there is publishing, so only that repo's own work belongs in it and secrets or personal/work data never do"
            "- **Internal sharing / snippet hosting**: None configured; public paste/gist services are outside the trust boundary"
            "- **Secrets management**: agenix-rekey. Age-encrypted `*.age` files under ~/nixos/secrets (master identity secrets/yubikey-identity.pub, YubiKey-backed) decrypt at activation to /run/agenix and /run/user/<uid>/agenix. Edited only via `just secret-edit`/`secret-generate`/`secret-rekey`; decrypted contents are never printed, copied or committed. CI secrets: the repository secrets referenced in .github/workflows"
            "- **Default / protected branches**: `main` is the default and protected branch of ~/nixos (plus one ruleset); a nightly update bot opens an automerged PR against it"
            "- **CI/CD deploy targets**: None configured; hosts are activated by hand with `just switch`/`boot` (this machine) or `just deploy-remote` (another host), all of which change a live system"
            "- **Network posture**: ordinary internet access plus a Tailscale tailnet"
            "- **Host containment**: None; Claude Code runs unsandboxed with the user's full privileges on their own workstations (NixOS, nix-darwin or standalone home-manager)"
            (
              "- **Source control**: github.com/nickolaj-jepsen (personal)"
              + lib.optionalString work " and github.com/Digital-Udvikling (work)"
            )
            (
              if work
              then "- **Trusted internal domains**: aortl.net (work internal services, e.g. insight.mcp.aortl.net, metabase.aortl.net)"
              else "- **Trusted internal domains**: None configured"
            )
            "- **Trusted cloud buckets**: None configured"
            (
              if work
              then "- **Key internal services**: work Linear, Sentry, Grafana, Metabase and GrowthBook (via MCP); a homelab Grafana"
              else "- **Key internal services**: a homelab Grafana"
            )
            "- **Internal package registry**: an attic Nix binary cache on the homelab (attic.<HOMELAB_DOMAIN>)"
            "- **Sensitive data locations & audiences**: ~/nixos/secrets/** (`*.age`), /run/agenix, /run/user/*/agenix, ~/.ssh, ~/.claude/.credentials.json, ~/.claude-work/.credentials.json, `.env` files; share only with audiences cleared at the [named+specifics] bar"
            "- **Data retention / declassification**: None configured"
            "- **Sensitive remote targets**: any namespace, host, context or container whose name carries prod or production as a whole word or name segment; ~/nixos/secrets/k8s/ao-prod.age is encrypted material, not a live target"
            (
              if work
              then "- **Protected deployment namespaces / environments**: `ao-prod` (work Kubernetes); otherwise fall back to the Sensitive remote targets heuristic"
              else "- **Protected deployment namespaces / environments**: None configured; fall back to the Sensitive remote targets heuristic"
            )
            "- **Protected IaC scopes**: IAM, RBAC, networking, quota and node-pool resources; anything whose name or tag carries prod or production as a whole word or name segment"
            "### User-specific"
            (
              "- **Primary use of Claude Code**: the user's own Nix system configuration (flakes, home-manager, agenix) and hobby projects"
              + lib.optionalString work "; on this host also software development for Digital-Udvikling"
            )
            "- **Trusted repo**: ~/nixos (PUBLIC, see Repository visibility) and the user's own checkouts under ~/dev"
            "- **Org-specific CLIs**: `just` (task runner in ~/nixos), agenix/age (secrets)"
          ]
          ++ onWork "- **Org-specific CLIs (work)**: `ds` (Digital-Udvikling repositories only), `kubectl` (work clusters)"
          ++ [
            "- routine under ~/nixos: `nix eval`/`build`/`fmt`/`flake check`, `just build`/`diff`/`fmt`/`check`/`docs`, and commits on local branches"
          ];
        # Underlines misspelled words in the prompt input, in the theme's error
        # colour. Only ever read from user settings — a spellcheck block in a
        # repo's .claude/ is ignored.
        spellcheck = {
          enabled = true;
          checker = "hunspell";
          language = lib.concatStringsSep "," dictionaries;
        };
        # ctrl+q picks fixes for the words the underline flags (plugins/spellfix in agents).
        pluginConfigs.spellfix.options = {
          hunspell = lib.getExe spellChecker;
          dictionaries = lib.concatStringsSep "," dictionaries;
          inherit personalDictionary;
        };
        statusLine = {
          type = "command";
          command = lib.getExe statusLine;
          # Event-driven updates miss what other sessions and editors do to the checkout.
          refreshInterval = 2;
        };
        env = settingsEnv;
        # Private repo, so fetched by Claude Code at runtime with the user's git
        # credentials rather than as a flake input; no access just means no plugin.
        extraKnownMarketplaces = lib.mkIf cfg.work.enable {
          ao-agent-skills.source = {
            source = "github";
            repo = "Digital-Udvikling/skills";
          };
        };
        # Local skills win over claude.ai's copies: skills uploaded to the account
        # sync in as anthropic-skills:<name>, so a same-named one is switched off.
        # The rest trim the synced skills to the ones used from Claude Code.
        skillOverrides = let
          synced = state: names: lib.genAttrs (map (name: "anthropic-skills:${name}") names) (_: state);
        in
          synced "off" skillNames
          // synced "off" [
            "built-in-browser"
            "computer-use"
            "dk-car-search"
            "dk-house-search"
            "google-workspace"
            "import-memory"
            "morning"
          ]
          // synced "name-only" [
            "docx"
            "pdf"
            "pptx"
            "xlsx"
          ];
        # claude.ai connectors never called from Claude Code; each one lists its
        # tool names, and some their instructions, in every session.
        deniedMcpServers = map (name: {serverName = "claude.ai ${name}";}) [
          "Booking.com"
          "Excalidraw"
          "Figma"
          "flightpowers"
          "Google Calendar"
          "Google Drive"
          "home-assistant"
          "Kiwi.com"
          "lastminute.com"
          "Sentry"
          "Trivago"
        ];
        enabledPlugins =
          {
            "cc-plugin-you-should-know@builtin" = true;
            # This repo's own marketplace, synced back from the claude.ai account;
            # every skill in it is already installed locally.
            "skills@synced" = false;
            "cowork-plugin-management@synced" = false;
          }
          // lib.optionalAttrs cfg.work.enable {
            "ao-skills@ao-agent-skills" = true;
          };
        permissions = {
          # Each checkout's .agents/store link resolves here, which is outside
          # the working directory and so prompts on every write through the link.
          additionalDirectories = ["${config.xdg.dataHome}/agents/store"];
          # Only commands that are frequent AND slow to classify earn a rule: in
          # auto mode an allow rule buys determinism, not safety. Omitted on
          # purpose — the built-in read-only set (ls/cat/head/tail/grep/find/wc/
          # which/diff/stat/du and read-only git) never prompts in any mode, and
          # trivia like mkdir/touch/basename costs the classifier nothing.
          allow = [
            # Git — write verbs only.
            "Bash(git add:*)"
            "Bash(git commit:*)"
            # Not `git checkout:*`: `git checkout <path>` discards edits and no ask glob can tell a path from a branch.
            "Bash(git checkout -b:*)"
            "Bash(git switch:*)"
            "Bash(git stash:*)"
            "Bash(git fetch:*)"
            "Bash(git rebase:*)"
            "Bash(git merge:*)"
            "Bash(git cherry-pick:*)"
            "Bash(git worktree:*)"
            "Bash(git remote:*)"
            "Bash(git tag:*)"
            # Github
            "Bash(gh pr *)"
            "Bash(gh issue *)"
            "Bash(gh repo view *)"
            "Bash(gh run *)"
            # Cargo
            "Bash(cargo build:*)"
            "Bash(cargo test:*)"
            "Bash(cargo check:*)"
            "Bash(cargo clippy:*)"
            "Bash(cargo fmt:*)"
            # NPM / PNPM
            "Bash(npm run:*)"
            "Bash(npm test:*)"
            # Bare installs only: with args they add packages (or -g) and run their install scripts.
            "Bash(npm install)"
            "Bash(pnpm run:*)"
            "Bash(pnpm test:*)"
            "Bash(pnpm install)"
            "Bash(pnpm exec:*)"
            # Uv
            "Bash(uv sync)"
            "Bash(uv run:*)"
            # Nix
            "Bash(nix fmt:*)"
            "Bash(nix flake check:*)"
            "Bash(nix flake show:*)"
            "Bash(nix flake metadata:*)"
            "Bash(nix eval:*)"
            "Bash(nix build:*)"
            # Just
            "Bash(just:*)"
            # DS
            "Bash(ds:*)"

            # Tools
            "WebSearch"
          ];
          # Auto mode suspends wildcard and interpreter allow rules, but a narrow
          # one (`Bash(just:*)`) skips the classifier entirely — so commands that
          # touch the running system or outside world are pinned here, where
          # `ask` outranks `allow` in every mode. Destructive git is left to the classifier.
          ask = [
            "Bash(just switch:*)"
            "Bash(just boot:*)"
            "Bash(just deploy-remote:*)"
            "Bash(just gc:*)"
            # Prints plaintext to the transcript, sidestepping the agenix Read denies.
            "Bash(just decrypt:*)"
            "Bash(gh pr merge:*)"
            "Bash(gh pr create:*)"
            "Bash(gh pr comment:*)"
            "Bash(gh pr review:*)"
            "Bash(gh issue create:*)"
            "Bash(gh issue comment:*)"
            # Scaleway: ao-prod is not read-only (same full-access user key as
            # ao-dev), so the profile name carries the whole warning.
            "Bash(*ao-prod*)"
            "Bash(*b2c-production*)"
            "Bash(scw * delete*)"
            "Bash(scw * terminate *)"
            "Bash(scw * poweroff *)"
            "Bash(scw * reboot *)"
          ];
          # Read rules cover the file tools only — Bash can still cat these. agenix
          # decrypts to /run, and the ~/.ssh keys are symlinks into it.
          deny =
            [
              "Read(//run/agenix/**)"
              "Read(//run/user/*/agenix/**)"
              "Read(~/.ssh/id_*)"
              "Read(~/.claude/.credentials.json)"
              "Read(~/.claude-work/.credentials.json)"
              "Read(**/.env)"
              # Holds both Scaleway key pairs; pi denies this path via age.secrets.
              "Read(~/.config/scw/config.yaml)"
              # Print the plaintext key into the transcript, sidestepping the Read deny.
              "Bash(scw config get secret-key)"
              "Bash(scw config dump)"
            ]
            ++ lib.optional phoenix.enabled "Read(/${phoenix.path})";
        };
      };
    };
  };
}
