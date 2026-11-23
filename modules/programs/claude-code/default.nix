# Always-on; the claude-work wrapper is gated by claude-code.work.enable.
{
  fpLib,
  inputs,
  ...
}: {
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
    scratch = config.fireproof.dev.enable;
    phoenix = import ../_phoenix-client.nix {inherit config;};
    phoenixHeaders = pkgs.writeShellScript "claude-phoenix-headers" ''
      key=$(<${lib.escapeShellArg phoenix.path}) || exit 1
      [ -n "$key" ] || exit 1
      printf '%s' "$key" | ${lib.getExe pkgs.jq} -Rs '{Authorization: ("Bearer " + sub("[\\r\\n]+$"; ""))}'
    '';

    # Agent temp is the repository's scratch root, aged out by `agent-notes reap`
    # (docs/notes.md). Not a per-pid directory: Claude Code keys its
    # scratchpad by session id under TMPDIR, so a resumed session finds it again.
    # Falls back to the ambient TMPDIR when it cannot be created.
    tmpDir = ''
      if TMPDIR=$(${lib.getExe pkgs.agent-notes} tmp --repo); then export TMPDIR; fi
    '';

    # One auto-memory per repository, shared by worktrees and both profiles. Flag
    # settings, since autoMemoryDirectory must be absolute and is ignored in a
    # checked-in .claude/settings.json. `global` is agent-notes' outside-git store.
    memoryArgs = ''
      memory_args=()
      if id=$(${lib.getExe pkgs.agent-notes} id 2>/dev/null) && [ "$id" != global ]; then
        memory_args=(--settings "$(${lib.getExe pkgs.jq} -cn --arg dir "${config.xdg.dataHome}/agents/claude-memory/$id" '{autoMemoryDirectory: $dir}')")
      fi
    '';

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
      runtimeEnv.LOCAL_SKILLS = pkgs.writeText "claude-local-skills" (lib.concatLines (lib.attrNames ccfg.skills));
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

    # A plugin of nickolaj-jepsen/agents: validated and tested against the claude-code that
    # runs it, so a bump that breaks its API (or drops the keybinding action spellfix borrows)
    # fails the build.
    mkToolMod = inputs.agents.lib.mkClaudePlugin {
      inherit pkgs;
      claude-code = ccfg.package;
    };
    # Every plugin of agents with a Claude half. linear-issue's button is spliced into the
    # built-in you-should-know card by label; a card redesign only hides it, with a toast.
    claudePlugins = lib.attrNames (lib.filterAttrs (_: plugin: plugin.claude) inputs.agents.lib.plugins);
    mods = lib.genAttrs claudePlugins mkToolMod;
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

    phoenixTracing = {
      project,
      profileCheck,
    }:
      lib.optionalString phoenix.enabled ''
        if [ -s ${lib.escapeShellArg phoenix.path} ] && ${profileCheck}; then
          ${phoenix.clear}
          export CLAUDE_CODE_ENABLE_TELEMETRY=1 CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
          export OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none
          export OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=http/protobuf
          export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=${lib.escapeShellArg phoenix.endpoint}
          export OTEL_RESOURCE_ATTRIBUTES=openinference.project.name=${project}
          export OTEL_LOG_USER_PROMPTS=1 OTEL_LOG_TOOL_DETAILS=1 OTEL_LOG_TOOL_CONTENT=1
          empty_settings='{}'
          if settings=$(${lib.getExe pkgs.jq} -c --arg helper ${lib.escapeShellArg (toString phoenixHeaders)} '. + {otelHeadersHelper: $helper}' <<< "''${memory_args[1]:-$empty_settings}"); then
            memory_args=(--settings "$settings")
          else
            ${phoenix.clear}
          fi
        fi
      '';

    # `claude plugin test` refuses any option before `plugin`, and the
    # home-manager wrapper always prepends --plugin-dir.
    claudeEntry = pkgs.writeShellScript "claude" ''
      ${lib.optionalString scratch tmpDir}
      if [ "''${1:-}" = plugin ]; then exec -a "$0" ${lib.getExe ccfg.package} "$@"; fi
      ${memoryArgs}
      ${phoenixTracing {
        project = "claude-code";
        profileCheck = ''[ -z "''${CLAUDE_CONFIG_DIR:-}" ]'';
      }}
      exec -a "$0" ${ccfg.finalPackage}/bin/claude "''${memory_args[@]}" "$@"
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
        ${lib.optionalString scratch tmpDir}
        ${phoenix.clear}
        export CLAUDE_CODE_ENABLE_TELEMETRY=0 OTEL_TRACES_EXPORTER=none
        export CLAUDE_CONFIG_DIR="''${CLAUDE_CONFIG_DIR:-$HOME/.claude-work}"
        mkdir -p "$CLAUDE_CONFIG_DIR"
        ${memoryArgs}
        ${phoenixTracing {
          project = "claude-work";
          profileCheck = ''[ "$CLAUDE_CONFIG_DIR" = "$HOME/.claude-work" ]'';
        }}
        exec ${ccfg.finalPackage}/bin/claude ${lib.escapeShellArgs workMcpArgs} "''${memory_args[@]}" "$@"
      '';
    };

    # The agents checkout's mods in place of the store copies, so a save reloads them without
    # a switch. An emptied CLAUDE_CODE_PLUGIN_DIRS beats the one in settings' env.
    claudeDev = pkgs.writeShellApplication {
      name = "claude-dev";
      text = ''
        checkout="${config.fireproof.agents.devCheckout}"
        args=()
        for manifest in "$checkout"/plugins/*/.claude-plugin/plugin.json; do
          [ -f "$manifest" ] && args+=(--plugin-dir "''${manifest%/.claude-plugin/plugin.json}")
        done
        [ ''${#args[@]} -gt 0 ] || { echo "claude-dev: no mods under $checkout" >&2; exit 1; }
        CLAUDE_CODE_PLUGIN_DIRS="" exec claude "''${args[@]}" "$@"
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
      ++ lib.optional (ccfg.skills != {}) "skills"
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

    home.activation.hunspellPersonalDictionary = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run mkdir -p ${lib.escapeShellArg (dirOf personalDictionary)}
      [ -e ${lib.escapeShellArg personalDictionary} ] || run touch ${lib.escapeShellArg personalDictionary}
    '';

    home.packages = [spellChecker claudeDev] ++ lib.optional cfg.work.enable claudeWorkWrapper;

    programs.claude-code.context = builtins.readFile ../agent-context.md;

    programs.claude-code = {
      enable = true;
      package = pkgs.claude-code;
      enableMcpIntegration = true;
      # The fireproof.agents.skills registry.
      skills = config.fireproof.agents.skills;

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
            SessionStart = direnvHooks;
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
        env = {
          # Not programs.claude-code.plugins: the env block also reaches desktop-app sessions.
          CLAUDE_CODE_PLUGIN_DIRS = lib.concatMapStringsSep ":" (name: "${mods.${name}}") loadOrder;
          # hunspell's personal dictionary for the underline's checker too.
          WORDLIST = personalDictionary;
        };
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
          synced "off" (lib.attrNames ccfg.skills)
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
          # Each checkout's .agents/ links resolve here, which is outside
          # the working directory and so prompts on every write through the link.
          additionalDirectories = [
            "${config.xdg.dataHome}/agents/store"
            "${config.xdg.stateHome}/agents/tmp"
            "${config.xdg.dataHome}/agents/claude-memory"
          ];
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
