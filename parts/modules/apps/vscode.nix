{
  pkgsUnstable,
  pkgs,
  inputs,
  lib,
  ...
}: let
  # stable = inputs.nix-vscode-extensions.extensions.${pkgs.system}.vscode-marketplace-release;
  vscode-extensions = inputs.nix-vscode-extensions.extensions.${pkgs.system};
  vscodePackage = pkgsUnstable.vscode;
  vscodeMarketplace = (vscode-extensions.forVSCodeVersion vscodePackage.version).vscode-marketplace;
  vscodeMarketplaceRelease = (vscode-extensions.forVSCodeVersion vscodePackage.version).vscode-marketplace-release;
  vscodePkgs = vscodeMarketplace // vscodeMarketplaceRelease; # Prefer release over pre-release

  mkFormatter = formatter: languages: {
    "[${lib.concatStringsSep "][" languages}]" = {
      editor.defaultFormatter = formatter;
      editor.formatOnSave = true;
    };
  };
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
          extensions.ignoreRecommendations = true;

          # Remote
          remote.SSH.useLocalServer = false;

          # AI
          github.copilot.editor.enableAutoCompletions = true;
          github.copilot.enable."*" = true;

          # Theme
          workbench.colorTheme = "Darcula Theme from IntelliJ";

          # Keybindings
          workbench.commandPalette.experimental.suggestCommands = true; # Emulates IntelliJ's "Search Everywhere"
        }
        (mkFormatter "esbenp.prettier-vscode" ["json" "jsonc" "markdown" "css" "scss" "typescript" "typescriptreact" "html" "yaml"])
        (mkFormatter "charliermarsh.ruff" ["python"])
      ];
      extensions = with vscodePkgs; [
        # Remote
        ms-vscode-remote.remote-ssh

        # AI
        github.copilot
        github.copilot-chat

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
