{
  pkgsUnstable,
  pkgs,
  inputs,
  lib,
  ...
}: let
  vscodePackage = pkgsUnstable.vscode;
  vscode-extensions = inputs.nix-vscode-extensions.extensions.${pkgs.system};
  vscodePkgs = vscode-extensions.vscode-marketplace // vscode-extensions.vscode-marketplace-release; # Prefer release over pre-release

  mkFormatter = formatter: languages: {
    "[${lib.concatStringsSep "][" languages}]" = {
      "editor.defaultFormatter" = formatter;
      "editor.formatOnSave" = true;
    };
  };

  # I can't get nix-vscode-extensions to respect allowUnfree, so this is a workaround
  allowUnfree = ext: ext.override {meta.license = [];};
in {
  fireproof.home-manager = {
    programs.vscode = {
      enable = true;
      package = vscodePackage;
      enableUpdateCheck = true;
      enableExtensionUpdateCheck = true;
      userSettings = lib.mkMerge [
        {
          # General
          "extensions.ignoreRecommendations" = true;

          # Remote
          "remote.SSH.useLocalServer" = false;
          "remote.SSH.remotePlatform" = {"*" = "linux";};

          # AI
          "github.copilot.editor.enableAutoCompletions" = true;
          "github.copilot.enable" = {"*" = true;};

          # Theme
          "workbench.colorTheme" = "Darcula Theme from IntelliJ";
          "window.titleBarStyle" = "custom";

          # Keybindings
          "workbench.commandPalette.experimental.suggestCommands" = true; # Emulates IntelliJ's "Search Everywhere"

          # nix-ide
          "nix.enableLanguageServer" = true;
          "nix.serverPath" = lib.getExe pkgs.nil;

          "nix.serverSettings" = {
            nil.formatting.command = ["nix" "fmt" "--" "--"];
          };
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
}
