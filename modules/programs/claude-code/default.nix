# Always-on; the claude-work wrapper is gated by claude-code.work.enable.
{
  flake.modules.homeManager.claude-code = {
    pkgs,
    config,
    lib,
    ...
  }: let
    cfg = config.fireproof.claude-code;
    hmLib = config.lib;
    homeDir = config.home.homeDirectory;

    claudeWorkWrapper = pkgs.writeShellApplication {
      name = "claude-work";
      runtimeInputs = [config.programs.claude-code.finalPackage];
      text = ''
        export CLAUDE_CONFIG_DIR="''${CLAUDE_CONFIG_DIR:-$HOME/.claude-work}"
        mkdir -p "$CLAUDE_CONFIG_DIR"
        exec claude "$@"
      '';
    };

    workFiles = lib.mkIf cfg.work.enable {
      ".claude-work/settings.json".source = hmLib.file.mkOutOfStoreSymlink "${homeDir}/.claude/settings.json";
      ".claude-work/CLAUDE.md".source = hmLib.file.mkOutOfStoreSymlink "${homeDir}/.claude/CLAUDE.md";
      ".claude-work/commands".source = hmLib.file.mkOutOfStoreSymlink "${homeDir}/.claude/commands";
      ".claude-work/skills".source = hmLib.file.mkOutOfStoreSymlink "${homeDir}/.claude/skills";
      ".claude-work/plugins".source = hmLib.file.mkOutOfStoreSymlink "${homeDir}/.claude/plugins";
    };
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

      settings = {
        tui = "fullscreen";
        voiceEnabled = true;
        useAutoModeDuringPlan = true;
        skipAutoPermissionPrompt = true;
        preferredNotifChannel = "terminal_bell";
        env = {
          CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
        };
        permissions = {
          allow = [
            # Git
            "Bash(git status:*)"
            "Bash(git diff:*)"
            "Bash(git log:*)"
            "Bash(git add:*)"
            "Bash(git commit:*)"
            "Bash(git branch:*)"
            "Bash(git checkout:*)"
            "Bash(git stash:*)"
            "Bash(git fetch:*)"
            "Bash(git rebase:*)"
            "Bash(git merge:*)"
            "Bash(git cherry-pick:*)"
            "Bash(git worktree:*)"
            "Bash(git show:*)"
            "Bash(git remote:*)"
            "Bash(git rev-parse:*)"
            "Bash(git reset:*)"
            "Bash(git tag:*)"
            # Github
            "Bash(gh pr *)"
            "Bash(gh issue *)"
            "Bash(gh repo view *)"
            "Bash(gh run *)"

            # Unix basics
            "Bash(ls:*)"
            "Bash(find:*)"
            "Bash(wc:*)"
            "Bash(head:*)"
            "Bash(tail:*)"
            "Bash(which:*)"
            "Bash(echo:*)"
            "Bash(cat:*)"
            "Bash(mkdir:*)"
            "Bash(touch:*)"
            "Bash(dirname:*)"
            "Bash(basename:*)"
            "Bash(realpath:*)"
            "Bash(uname:*)"
            "Bash(tree:*)"

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
          deny = [
            "Bash(rm -rf /)"
            "Bash(sudo rm:*)"
            "Edit(.env)"
          ];
        };
      };
    };
  };
}
