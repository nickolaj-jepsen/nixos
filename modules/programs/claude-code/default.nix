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

    # Surfaces the session state deliberately left out of settings.json (model,
    # effort, fast mode) plus which profile is running — claude-work shares this
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
            [
              (if $profile == "work" then "\($warn)work\($reset)" else empty end),
              .model.display_name,
              (.effort.level // empty),
              (if .fast_mode then "fast" else empty end),
              (if pct > 80
               then "\($warn)\(pct)%\($reset)"
               else "\($dim)\(pct)%\($reset)" end)
            ] | join("\($dim) · \($reset)")
          '
      '';
    };

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

    home.packages = lib.optional cfg.work.enable claudeWorkWrapper;

    # Shared with copilot (agents.nix) and pi; keep it agent-agnostic.
    programs.claude-code.context = builtins.readFile ../agent-context.md;

    programs.claude-code = {
      enable = true;
      package = pkgs.claude-code;
      enableMcpIntegration = true;
      # The fireproof.agents.skills registry: repo-root skills/ (registered by
      # agent-skills.nix; see skills/README.md) plus skills registered by
      # feature leaves. One file per command (commands/<name>.md).
      skills = config.fireproof.agents.skills;
      commandsDir = ./commands;

      # Real go-to-definition/find-references/diagnostics instead of grep. Mirrors
      # neovim's full tier (modules/programs/neovim.nix), so nixd/pyrefly/tsserver
      # cost no extra closure; rust-analyzer replaces the hand-installed
      # rust-analyzer-lsp plugin. Store paths, not bare names — claude-code spawns
      # these itself and inherits whatever PATH the terminal had.
      lspServers = {
        nix = {
          command = lib.getExe pkgs.nixd;
          extensionToLanguage.".nix" = "nix";
        };
        python = {
          command = lib.getExe pkgs.pyrefly;
          args = ["lsp"];
          extensionToLanguage = {
            ".py" = "python";
            ".pyi" = "python";
          };
        };
        typescript = {
          command = lib.getExe pkgs.typescript-language-server;
          args = ["--stdio"];
          extensionToLanguage = {
            ".ts" = "typescript";
            ".mts" = "typescript";
            ".cts" = "typescript";
            ".tsx" = "typescriptreact";
            ".js" = "javascript";
            ".mjs" = "javascript";
            ".cjs" = "javascript";
            ".jsx" = "javascriptreact";
          };
        };
        rust = {
          command = lib.getExe pkgs.rust-analyzer;
          extensionToLanguage.".rs" = "rust";
        };
      };

      settings = {
        tui = "fullscreen";
        voiceEnabled = true;
        useAutoModeDuringPlan = true;
        skipAutoPermissionPrompt = true;
        preferredNotifChannel = "terminal_bell";
        statusLine = {
          type = "command";
          command = lib.getExe statusLine;
        };
        env = {
          CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
        };
        permissions = {
          # Only commands that are frequent AND slow to classify earn a rule: in
          # auto mode an allow rule buys determinism, not safety. Omitted on
          # purpose — the built-in read-only set (ls/cat/head/tail/grep/find/wc/
          # which/diff/stat/du and read-only git) never prompts in any mode, and
          # trivia like mkdir/touch/basename costs the classifier nothing.
          allow = [
            # Git — write verbs only; the destructive ones are in `ask` below.
            "Bash(git add:*)"
            "Bash(git commit:*)"
            "Bash(git checkout:*)"
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
            "Bash(npm install:*)"
            "Bash(pnpm run:*)"
            "Bash(pnpm test:*)"
            "Bash(pnpm install:*)"
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
            "Bash(nix develop:*)"
            "Bash(nix repl:*)"
            # Just
            "Bash(just:*)"
            # DS
            "Bash(ds:*)"

            # Tools
            "WebSearch"
          ];
          # Auto mode suspends wildcard and interpreter allow rules, but a narrow
          # one (`Bash(just:*)`) skips the classifier entirely — so the commands
          # whose blast radius is the running system or unrecoverable work are
          # pinned here, where `ask` outranks `allow` in every mode.
          ask = [
            "Bash(just switch:*)"
            "Bash(just boot:*)"
            "Bash(git reset:*)"
            "Bash(git push --force*:*)"
            "Bash(git clean:*)"
            "Bash(gh pr merge:*)"
          ];
          # Read rules cover the file tools only — Bash can still cat these. The
          # targets are the plaintext ones: agenix decrypts to /run, and ~/.ssh
          # keys are symlinks into it. secrets/ is deliberately absent, it holds
          # nothing but .age blobs.
          deny = [
            "Read(//run/agenix/**)"
            "Read(//run/user/*/agenix/**)"
            "Read(~/.ssh/**)"
            "Read(~/.claude/.credentials.json)"
            "Read(**/.env)"
            "Read(**/.env.*)"
            "Edit(.env)"
          ];
        };
      };
    };
  };
}
