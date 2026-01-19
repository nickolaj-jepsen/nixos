# Enabled when: desktop & dev
{
  config,
  lib,
  pkgsUnstable,
  pkgs,
  inputs,
  ...
}: let
  vscodePackage = pkgsUnstable.vscode;

  vscode-extensions = inputs.nix-vscode-extensions.extensions.${pkgs.stdenv.hostPlatform.system};
  vscodePkgs = vscode-extensions.vscode-marketplace // vscode-extensions.vscode-marketplace-release; # Prefer release over pre-release

  mkFormatter = formatter: languages: {
    "[${lib.concatStringsSep "][" languages}]" = {
      "editor.defaultFormatter" = formatter;
    };
  };

  # I can't get nix-vscode-extensions to respect allowUnfree, so this is a workaround
  allowUnfree = ext: ext.override {meta.license = [];};
in {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager = {
      programs.vscode = {
        enable = true;
        package = vscodePackage;
        profiles.default = {
          enableUpdateCheck = true;
          enableExtensionUpdateCheck = true;
          userMcp = {
            inputs = [
              {
                type = "promptString";
                id = "context7-api-key";
                description = "Context7 API Key";
                password = true;
              }
            ];
            servers = {
              linear = {
                url = "https://mcp.linear.app/mcp";
                type = "http";
              };
              sentry = {
                url = "https://mcp.sentry.dev/mcp";
                type = "http";
              };
              figma = {
                url = "https://mcp.figma.com/mcp";
                type = "http";
              };
              context7 = {
                type = "http";
                url = "https://mcp.context7.com/mcp";
                headers = {
                  CONTEXT7_API_KEY = "\${input:context7-api-key}";
                };
              };
              insight = {
                url = "https://insight.mcp.aortl.net/mcp";
                type = "http";
              };
            };
          };
          keybindings = [
            {
              "key" = "ctrl+shift+p";
              "command" = "editor.action.formatDocument";
            }
          ];
          userSettings = lib.mkMerge [
            {
              # General
              "extensions.ignoreRecommendations" = true;
              "telemetry.telemetryLevel" = "off";
              "update.mode" = "none"; # Managed by Nix

              # Editor
              "editor.linkedEditing" = true;
              "editor.formatOnPaste" = true;
              "editor.bracketPairColorization.enabled" = true;
              "editor.guides.bracketPairs" = "active";
              "editor.cursorSmoothCaretAnimation" = "on";
              "editor.stickyScroll.enabled" = true;
              "editor.inlayHints.enabled" = "onUnlessPressed";
              "editor.renderWhitespace" = "boundary";

              # Files
              "files.autoSave" = "afterDelay";
              "files.trimTrailingWhitespace" = true;
              "files.insertFinalNewline" = true;
              "files.trimFinalNewlines" = true;
              "files.exclude" = {
                "**/*.egg-info" = true;
                "**/__pycache__" = true;
                "**/.git" = true;
                "**/.DS_Store" = true;
                "**/node_modules" = true;
                "**/.direnv" = true;
              };

              # Workbench
              "workbench.editor.wrapTabs" = true;
              "workbench.startupEditor" = "none";
              "workbench.tree.indent" = 16;
              "workbench.editor.highlightModifiedTabs" = true;
              "workbench.editor.limit.enabled" = true;
              "workbench.editor.limit.value" = 10;
              "workbench.editor.limit.perEditorGroup" = true;

              # Terminal
              "terminal.integrated.defaultProfile.linux" = "fish";
              "terminal.integrated.smoothScrolling" = true;
              "terminal.integrated.cursorBlinking" = true;

              # Remote
              "remote.SSH.useLocalServer" = false;
              "remote.SSH.remotePlatform" = lib.mapAttrs (_name: _value: "linux") config.fireproof.home-manager.programs.ssh.matchBlocks;

              # AI
              "github.copilot.enable" = {
                "*" = true;
                "plaintext" = true;
                "markdown" = true;
                "scminput" = true;
              };
              "chat.agent.enabled" = true;
              "github.copilot.chat.agent.thinkingTool" = true;
              "github.copilot.chat.codesearch.enabled" = true;
              "github.copilot.nextEditSuggestions.enabled" = true;
              "github.copilot.chat.githubMcpServer.enabled" = true;
              "chat.customAgentInSubagent.enabled" = true;
              "inlineChat.enableV2" = true;
              "chat.viewSessions.orientation" = "vertical";
              "chat.agent.maxRequests" = 100;

              "chat.tools.terminal.autoApprove" = {
                "nix" = true;
                "cat" = true;
                "ls" = true;
                "head" = true;
                "tail" = true;
                "find" = true;
                "grep" = true;
                "rg" = true;
                "fd" = true;
                "echo" = true;
                "jq" = true;
                "pwd" = true;
                "wc" = true;
                "which" = true;
                "git status" = true;
                "git log" = true;
                "git diff" = true;
                "git branch" = true;
                "git show" = true;
                "uv" = true;
                "python" = true;
                "pip" = true;
                "npm" = true;
                "npx" = true;
                "pnpm" = true;
                "yarn" = true;
                "node" = true;
                "cargo" = true;
                "rustc" = true;
                "go" = true;
                "just" = true;
                "make" = true;
              };

              # Theme
              "workbench.colorTheme" = "Darcula Theme from IntelliJ";
              "window.titleBarStyle" = "custom";
              "editor.fontFamily" = "'Hack Nerd Font', 'Hack', 'monospace', monospace";
              "editor.fontSize" = 14;
              "editor.lineHeight" = 1.5;

              # Keybindings
              "workbench.commandPalette.experimental.suggestCommands" = true; # Emulates IntelliJ's "Search Everywhere"

              # Git
              "git.autofetch" = true;
              "git.confirmSync" = false;
              "git.enableSmartCommit" = true;
              "diffEditor.ignoreTrimWhitespace" = false;
              "scm.repositories.explorer" = true;

              # GitHub
              "githubPullRequests.codingAgent.uiIntegration" = true;
              "githubPullRequests.pullBranch" = "always";

              # nix-ide
              "nix.enableLanguageServer" = true;
              "nix.serverPath" = lib.getExe pkgs.nil;
              "nix.serverSettings" = {
                nil.formatting.command = ["nix" "fmt" "--" "--"];
              };

              # Python
              "python.analysis.autoImportCompletions" = true;

              # Other extensions
              "biome.suggestInstallingGlobally" = false;
            }
            (mkFormatter "esbenp.prettier-vscode" ["json" "jsonc" "markdown" "css" "scss" "typescript" "typescriptreact" "html" "yaml"])
            (mkFormatter "charliermarsh.ruff" ["python"])
          ];
          extensions = with vscodePkgs; [
            # Remote
            (allowUnfree ms-vscode-remote.remote-ssh)

            # AI
            (allowUnfree github.copilot)
            (allowUnfree github.copilot-chat)

            # Git(hub)
            github.vscode-pull-request-github

            # Python
            ms-pyright.pyright
            ms-python.python
            charliermarsh.ruff

            # JavaScript
            dbaeumer.vscode-eslint
            esbenp.prettier-vscode

            # Nix
            jnoortheen.nix-ide

            # Other languages
            nefrob.vscode-just-syntax
            redhat.vscode-yaml

            # Theme
            trinm1709.dracula-theme-from-intellij

            # Keybindings
            k--kato.intellij-idea-keybindings
          ];
        };
      };
    };
  };
}
