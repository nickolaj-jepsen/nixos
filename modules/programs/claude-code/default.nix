# Always-on; the claude-work wrapper is gated by claude-code.work.enable.
{
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

    # Surfaces session state that settings.json can't pin (model, effort as
    # changed by /effort, fast mode) plus which profile is running — claude-work shares this
    # file and CLAUDE.md by symlink, so nothing else distinguishes the two.
    # ANSI codes only, so the ghostty Flexoki palette stays authoritative.
    statusLine = pkgs.writeShellApplication {
      name = "claude-statusline";
      runtimeInputs = [pkgs.jq];
      text = ''
        profile=personal
        case "''${CLAUDE_CONFIG_DIR:-}" in
          *.claude-work) profile=work ;;
        esac

        jq -r \
          --arg profile "$profile" \
          --arg dim "$(printf '\033[2m')" \
          --arg warn "$(printf '\033[33m')" \
          --arg reset "$(printf '\033[0m')" '
            def pct: (.context_window.used_percentage // 0);
            # resets_at is epoch seconds per the docs; the ISO branch is a guard, not a known format.
            def hhmm: (if type == "number" then . else sub("\\.[0-9]+"; "") | fromdateiso8601 end)
              | strflocaltime("%H:%M");
            # Plan limits are absent on API-key sessions and before the first response.
            def limit($label; $window; $withReset):
              ($window.used_percentage // 0) as $p
              | if $p < 70 then empty
                else "\($warn)\($label) \($p | floor)%"
                  + (if $withReset then (try " ↻\($window.resets_at | hhmm)" catch "") else "" end)
                  + $reset
                end;
            [
              (if $profile == "work" then "\($warn)work\($reset)" else empty end),
              .model.display_name,
              (.effort.level // empty),
              (if .fast_mode then "fast" else empty end),
              (if pct > 80
               then "\($warn)\(pct)%\($reset)"
               else "\($dim)\(pct)%\($reset)" end),
              limit("5h"; .rate_limits.five_hour; true),
              limit("7d"; .rate_limits.seven_day; false)
            ] | join("\($dim) · \($reset)")
          '
      '';
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

    # claude-code resolves the checker off PATH by bare name, so it has to be a
    # real package rather than a store path like the LSP servers. hunspell
    # over aspell because only it takes several dictionaries at once (`-d a,b`).
    spellChecker = pkgs.hunspell.withDicts (d: [d.en_US d.da_DK]);

    claudeWorkWrapper = pkgs.writeShellApplication {
      name = "claude-work";
      runtimeInputs = [config.programs.claude-code.finalPackage];
      text = ''
        export CLAUDE_CONFIG_DIR="''${CLAUDE_CONFIG_DIR:-$HOME/.claude-work}"
        mkdir -p "$CLAUDE_CONFIG_DIR"
        exec claude "$@"
      '';
    };

    # Every config surface home-manager generates under ~/.claude, derived from the
    # options rather than hand-listed: a surface added below (agents, rules, hooks,
    # output-styles) would otherwise silently never reach the work profile.
    # `plugins` is shared mutable state, so it is always mirrored.
    mirroredNames =
      ["settings.json" "CLAUDE.md" "plugins"]
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
    # Mutes warning about installMethod by placing the wrapped binary in ~/.local/bin
    home.file = lib.mkMerge [
      {
        ".local/bin/claude".source = "${config.programs.claude-code.finalPackage}/bin/claude";
      }
      workFiles
    ];

    home.packages = [spellChecker] ++ lib.optional cfg.work.enable claudeWorkWrapper;

    # Shared by every agent; keep it agent-agnostic.
    programs.claude-code.context = builtins.readFile ../agent-context.md;

    programs.claude-code = {
      enable = true;
      package = pkgs.claude-code;
      enableMcpIntegration = true;
      # The fireproof.agents.skills registry. One file per command (commands/<name>.md).
      skills = config.fireproof.agents.skills;
      commandsDir = ./commands;

      # The fireproof.agents.lspServers registry (agent-lsp.nix); its rust-analyzer
      # replaces the hand-installed rust-analyzer-lsp plugin.
      lspServers = config.fireproof.agents.lspServers;

      settings = {
        tui = "fullscreen";
        voice.enabled = true;
        useAutoModeDuringPlan = true;
        skipAutoPermissionPrompt = true;
        # Drives niri's urgency hint; desktop toasts come from the Notification hook.
        preferredNotifChannel = "terminal_bell";
        # /effort saves per model under modelSettings, but settings.json is a
        # read-only store symlink, so those picks only last the session. Keys are
        # aliases, resolved like /model, so they follow new model releases; the
        # top-level level is the legacy default for models not listed.
        effortLevel = "high";
        modelSettings = {
          opus.effortLevel = "high";
          fable.effortLevel = "xhigh";
          sonnet.effortLevel = "medium";
        };
        hooks =
          {
            SessionStart = direnvHooks;
            CwdChanged = direnvHooks;
          }
          # macOS has desktop.enable too, but no notification daemon for notify-send.
          // lib.optionalAttrs (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
            Notification = [
              {
                matcher = "permission_prompt|idle_prompt|elicitation_dialog";
                hooks = [
                  {
                    type = "command";
                    command = "${lib.getExe pkgs.agent-notify} 'Claude Code'";
                  }
                ];
              }
            ];
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
            "- **Secrets management**: agenix-rekey. Age-encrypted `*.age` files under ~/nixos/secrets (master identity secrets/yubikey-identity.txt, YubiKey-backed) decrypt at activation to /run/agenix and /run/user/<uid>/agenix. Edited only via `just secret-edit`/`secret-generate`/`secret-rekey`; decrypted contents are never printed, copied or committed. CI secrets: ATTIC_TOKEN, BOT_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, HOMELAB_DOMAIN"
            "- **Default / protected branches**: `main` is the default and protected branch of ~/nixos (plus one ruleset); a nightly update bot opens an automerged PR against it"
            "- **CI/CD deploy targets**: None configured; hosts are activated by hand with `just switch`/`boot`/`home-switch`/`darwin-switch` (this machine) or `just deploy-remote` (another host), all of which change a live system"
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
            "- **Sensitive data locations & audiences**: ~/nixos/secrets/** (`*.age`, secrets/yubikey-identity.txt), /run/agenix, /run/user/*/agenix, ~/.ssh, ~/.claude/.credentials.json, ~/.claude-work/.credentials.json, `.env` files; share only with audiences cleared at the [named+specifics] bar"
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
            "- routine under ~/nixos: `nix eval`/`build`/`fmt`/`flake check`, `just build-system`/`diff`/`fmt`/`check`/`docs`, and commits on local branches"
          ];
        # Underlines misspelled words in the prompt input, in the theme's error
        # colour. Only ever read from user settings — a spellcheck block in a
        # repo's .claude/ is ignored.
        spellcheck = {
          enabled = true;
          checker = "hunspell";
          language = "en_US,da_DK";
        };
        statusLine = {
          type = "command";
          command = lib.getExe statusLine;
        };
        env = {
          CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
        };
        # Private repo, so fetched by Claude Code at runtime with the user's git
        # credentials rather than as a flake input; no access just means no plugin.
        extraKnownMarketplaces = lib.mkIf cfg.work.enable {
          ao-agent-skills.source = {
            source = "github";
            repo = "Digital-Udvikling/skills";
          };
        };
        enabledPlugins =
          {
            "cc-plugin-you-should-know@builtin" = true;
          }
          // lib.optionalAttrs cfg.work.enable {
            "ao-skills@ao-agent-skills" = true;
          };
        permissions = {
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
            "Bash(just home-switch:*)"
            "Bash(just darwin-switch:*)"
            "Bash(just deploy-remote:*)"
            "Bash(just bootstrap-flash:*)"
            "Bash(just gc:*)"
            # Prints plaintext to the transcript, sidestepping the agenix Read denies.
            "Bash(just decrypt:*)"
            "Bash(gh pr merge:*)"
          ];
          # Read rules cover the file tools only — Bash can still cat these. agenix
          # decrypts to /run, and the ~/.ssh keys are symlinks into it.
          deny = [
            "Read(//run/agenix/**)"
            "Read(//run/user/*/agenix/**)"
            "Read(~/.ssh/id_*)"
            "Read(~/.claude/.credentials.json)"
            "Read(~/.claude-work/.credentials.json)"
            "Read(**/.env)"
          ];
        };
      };
    };
  };
}
