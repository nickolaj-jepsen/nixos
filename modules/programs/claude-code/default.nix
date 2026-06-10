{
  pkgs,
  config,
  lib,
  ...
}: let
  inherit (config.fireproof) username;
  cfg = config.fireproof.claude-code;
  hmLib = config.home-manager.users.${username}.lib;
  homeDir = config.home-manager.users.${username}.home.homeDirectory;

  claudeWorkWrapper = pkgs.writeShellApplication {
    name = "claude-work";
    runtimeInputs = [config.home-manager.users.${username}.programs.claude-code.finalPackage];
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
  options.fireproof.claude-code.work.enable =
    lib.mkEnableOption "claude-work wrapper sharing the personal claude-code config via ~/.claude-work";

  config = {
    fireproof.home-manager = {
      # Mutes warning about installMethod by placing the wrapped binary in ~/.local/bin
      home.file = lib.mkMerge [
        {
          ".local/bin/claude".source = "${config.home-manager.users.${username}.programs.claude-code.finalPackage}/bin/claude";
        }
        workFiles
      ];

      home.packages = lib.optional cfg.work.enable claudeWorkWrapper;

      programs.claude-code.context = ''
        # Global preferences

        ## Environment
        - NixOS — declarative & immutable. Imperative installs (`apt`, `npm -g`, global `pip`) and `/etc` edits won't persist; system changes go through the flake at `~/nixos`. For a one-off tool, use [comma](https://github.com/nix-community/comma): `, pstree`, `, ncdu .`

        ## Tooling
        - Language toolchains — prefer uv (Python) and pnpm (Node), but defer to whatever the repo already uses.
        - Git: rebase over merge — even if I ask to "merge" — unless I explicitly say "use merge over rebase".
        - Digital-Udvikling repos (check git remote): use the `ds` CLI when applicable (run `ds --help` to see what it covers).

        ## Code style
        - Comments earn their place. The code already states *what* it does — don't restate it. Comment only what a competent reader can't recover from the code: the load-bearing *why* (intent, a gotcha, a non-obvious tradeoff). If nothing qualifies, write no comment.
        - Default to one line. Give the minimal why and stop; run past a line only when the rationale genuinely can't compress. Length is not thoroughness.
        - Docstrings state the function's own contract — what it does, params, returns, errors, invariants — and nothing else. Don't restate the signature; don't document who calls it or where ("used by the signup flow") — that belongs at the call site and goes stale here. Guidance on *when* to call it is fine.
      '';

      programs.claude-code = {
        enable = true;
        package = pkgs.claude-code;
        enableMcpIntegration = true;
        # One folder per skill (skills/<name>/SKILL.md), one file per command
        # (commands/<name>.md). avoid-ai-tropes source: https://tropes.fyi/tropes-md
        skills = ./skills;
        commandsDir = ./commands;

        settings = {
          voiceEnabled = true;
          useAutoModeDuringPlan = true;
          skipAutoPermissionPrompt = true;
          env = {
            CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
          };
          hooks = {
            Notification = [
              {
                matcher = "permission_prompt|idle_prompt";
                hooks = [
                  {
                    type = "command";
                    command = "printf '\\a' > /dev/tty";
                  }
                ];
              }
            ];
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
  };
}
