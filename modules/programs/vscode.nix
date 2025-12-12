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

  vscode-extensions = inputs.nix-vscode-extensions.extensions.${pkgs.system};
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

              # Editor
              "editor.linkedEditing" = true;
              "files.exclude" = {
                "**/*.egg-info" = true;
                "**/__pycache__" = true;
              };
              "workbench.editor.wrapTabs" = true;

              # Files
              "files.autoSave" = "afterDelay";

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
              "githubPullRequests.codingAgent.uiIntegration" = true;
              "githubPullRequests.pullBranch" = "always";

              # Theme
              "workbench.colorTheme" = "Darcula Theme from IntelliJ";
              "window.titleBarStyle" = "custom";
              "editor.fontFamily" = "'Hack Nerd Font', 'Hack', 'monospace', monospace";

              # Keybindings
              "workbench.commandPalette.experimental.suggestCommands" = true; # Emulates IntelliJ's "Search Everywhere"

              # nix-ide
              "nix.enableLanguageServer" = true;
              "nix.serverPath" = lib.getExe pkgs.nil;
              "nix.serverSettings" = {
                nil.formatting.command = ["nix" "fmt" "--" "--"];
              };

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
