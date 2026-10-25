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
    agentTmp = config.fireproof.agents.tmp.enable;

    # Agent temp lives in one root the janitor sweeps, named after the wrapper's
    # pid (exec keeps it), so a session that is gone can be proven gone. Falls
    # back to the ambient TMPDIR when the root cannot be created.
    tmpDir = ''
      if TMPDIR=$(${lib.getExe pkgs.agent-tmp} dir "$$"); then export TMPDIR; fi
    '';

    # Surfaces session state that settings.json can't pin (model, effort as
    # changed by /effort, fast mode), git state and the last response's
    # throughput, plus which profile is running — claude-work shares this
    # file and CLAUDE.md by symlink, so nothing else distinguishes the two.
    # ANSI codes only, so the ghostty Flexoki palette stays authoritative.
    statusLine = pkgs.writeShellApplication {
      name = "claude-statusline";
      runtimeInputs = [pkgs.jq pkgs.git pkgs.gh pkgs.coreutils pkgs.agent-tmp];
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

    # A PreToolUse hook that refuses `git worktree add` outside ~/worktrees/<repo>/.
    # The layout and the check live in `wt guard`, so pi and opencode enforce the
    # same rule; this only adds Claude's hook contract around it.
    worktreeGuard = pkgs.writeShellApplication {
      name = "claude-worktree-guard";
      runtimeInputs = [pkgs.jq pkgs.coreutils];
      text = builtins.readFile ./worktree-guard.sh;
    };

    # Claude Code's own worktrees (EnterWorktree, `claude -w`, agent isolation)
    # are created by `wt create`; removal stays Claude Code's own git fallback.
    worktreeHooks = pkgs.writeShellApplication {
      name = "claude-worktree-hooks";
      runtimeInputs = [pkgs.jq pkgs.coreutils];
      text = builtins.readFile ./worktree-hooks.sh;
    };
    worktreeCreate = [
      {
        hooks = [
          {
            type = "command";
            command = lib.getExe worktreeHooks;
          }
        ];
      }
    ];

    # pi toasts the moment a run ends; idle_prompt only fires a minute later.
    # Scripted runs (`claude -p`) have no terminal and nobody waiting on them,
    # and a turn paused on background work hasn't finished.
    finishNotify = pkgs.writeShellApplication {
      name = "claude-finish-notify";
      runtimeInputs = [pkgs.jq pkgs.coreutils pkgs.agent-notify];
      text = ''
        input=$(cat)
        case "$(readlink "/proc/$PPID/fd/0" 2>/dev/null)" in /dev/pts/* | /dev/tty*) ;; *) exit 0 ;; esac
        jq -e '(.background_tasks // []) == []' <<<"$input" >/dev/null || exit 0
        jq '.message = "Finished, waiting for input"' <<<"$input" | agent-notify 'Claude Code'
      '';
    };

    # claude-code resolves the checker off PATH by bare name, so it has to be a
    # real package rather than a store path like the LSP servers. hunspell
    # over aspell because only it takes several dictionaries at once (`-d a,b`).
    dictionaries = fpLib.hunspellLanguages;
    spellChecker = fpLib.mkHunspell pkgs;
    # Mutable: the spellfix picker adds words to it. hunspell neither creates a
    # missing personal dictionary nor saves into one, so activation touches it.
    personalDictionary = fpLib.hunspellPersonalDictionary config;

    # Validated and tested against the claude-code that runs it, so a bump that
    # breaks its API (or drops the keybinding action spellfix borrows) fails the build.
    mkMod = name:
      pkgs.stdenvNoCC.mkDerivation {
        name = "claude-code-${name}";
        src = ./mods/${name};
        nativeBuildInputs = [ccfg.package];
        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR"
          claude plugin validate .
          claude plugin test .
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -r .claude-plugin hooks types $out/
          runHook postInstall
        '';
      };
    spellfix = mkMod "spellfix";
    # Its button is spliced into the built-in you-should-know card by label; a
    # card redesign only hides it, with a toast (mods/linear-issue).
    linearIssue = mkMod "linear-issue";
    gitMenu = mkMod "git-menu";

    # ctrl+q presses spellfix's band button, which borrows this action; a
    # single modified key reaches a plugin Button only from the Global context.
    keybindings = {
      "$schema" = "https://www.schemastore.org/claude-code-keybindings.json";
      bindings = [
        {
          context = "Global";
          bindings."ctrl+q" = "app:toggleDiffNoiseFilter";
        }
      ];
    };

    # `claude plugin test` refuses any option before `plugin`, and the
    # home-manager wrapper always prepends --plugin-dir.
    claudeEntry = pkgs.writeShellScript "claude" ''
      ${lib.optionalString agentTmp tmpDir}
      if [ "''${1:-}" = plugin ]; then exec -a "$0" ${lib.getExe ccfg.package} "$@"; fi
      exec -a "$0" ${ccfg.finalPackage}/bin/claude "$@"
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
      cfg.workMcpServers;
    };
    workMcpPlugin = pkgs.runCommand "claude-code-work-mcp" {} ''
      install -Dm644 ${workMcpJson} $out/.mcp.json
      install -Dm644 ${jsonFormat.generate "claude-work-mcp-plugin.json" {name = "claude-work-mcp";}} $out/.claude-plugin/plugin.json
    '';
    workMcpArgs = lib.optionals (cfg.workMcpServers != {}) ["--plugin-dir" workMcpPlugin];

    claudeWorkWrapper = pkgs.writeShellApplication {
      name = "claude-work";
      runtimeInputs = [config.programs.claude-code.finalPackage];
      text = ''
        ${lib.optionalString agentTmp tmpDir}
        export CLAUDE_CONFIG_DIR="''${CLAUDE_CONFIG_DIR:-$HOME/.claude-work}"
        mkdir -p "$CLAUDE_CONFIG_DIR"
        exec claude ${lib.escapeShellArgs workMcpArgs} "$@"
      '';
    };

    # Every config surface home-manager generates under ~/.claude, derived from the
    # options rather than hand-listed: a surface added below (agents, rules, hooks,
    # output-styles) would otherwise silently never reach the work profile.
    # `plugins` is shared mutable state, so it is always mirrored.
    mirroredNames =
      ["settings.json" "CLAUDE.md" "plugins" "keybindings.json"]
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
        ".local/bin/claude".source = claudeEntry;
        # Replaces any hand-made file: bindings live in `keybindings` above.
        ".claude/keybindings.json" = {
          text = builtins.toJSON keybindings;
          force = true;
        };
      }
      workFiles
    ];

    home.activation.hunspellPersonalDictionary = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run mkdir -p ${lib.escapeShellArg (dirOf personalDictionary)}
      [ -e ${lib.escapeShellArg personalDictionary} ] || run touch ${lib.escapeShellArg personalDictionary}
    '';

    home.packages = [spellChecker] ++ lib.optional cfg.work.enable claudeWorkWrapper;

    # Shared by every agent; keep it agent-agnostic.
    programs.claude-code.context = ''
      ${builtins.readFile ../agent-context.md}
      ## Worktrees in Claude Code

      - Make or enter a worktree with `EnterWorktree` (`name` for a new one, which
        becomes its branch; `path` for an existing one) and leave with `ExitWorktree`.
        They create through `wt`, so the worktree lands under the shared root;
        `wt create` in Bash does not move the session.
      - `ExitWorktree` cannot see what a remove would discard, so it always asks for
        `discard_changes: true`. Check `git status` and `git log origin/<default>..`
        in the worktree first, and ask the user unless nothing would be lost. Claude's
        native removal leaves the branch behind.
      - Landing and clearing are explicit, and `wt --help` states their preconditions;
        nothing removes a worktree at exit.
    '';

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
        # Drives niri's urgency hint; desktop toasts come from the Notification and Stop hooks.
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
        hooks =
          {
            SessionStart = direnvHooks;
            CwdChanged = direnvHooks;
            WorktreeCreate = worktreeCreate;
            PreToolUse = [
              {
                matcher = "Bash";
                hooks =
                  [
                    {
                      type = "command";
                      command = lib.getExe worktreeGuard;
                    }
                  ]
                  # Nudge, never block: the janitor evicts dead sessions, so a live
                  # one holding the space is the one that has to give some back.
                  ++ lib.optional agentTmp {
                    type = "command";
                    command = "${lib.getExe pkgs.agent-tmp} warn";
                  };
              }
            ];
          }
          # macOS has desktop.enable too, but no notification daemon for notify-send.
          // lib.optionalAttrs (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
            Stop = [
              {
                hooks = [
                  {
                    type = "command";
                    command = lib.getExe finishNotify;
                  }
                ];
              }
            ];
            Notification = [
              {
                matcher = "permission_prompt|elicitation_dialog";
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
        # ctrl+q picks fixes for the words the underline flags (mods/spellfix).
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
          CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
          # Not programs.claude-code.plugins: the env block also reaches desktop-app sessions.
          CLAUDE_CODE_PLUGIN_DIRS = "${spellfix}:${linearIssue}:${gitMenu}";
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
