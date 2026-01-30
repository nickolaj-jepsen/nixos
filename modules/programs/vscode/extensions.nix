{
  config,
  lib,
  pkgsUnstable,
  pkgs,
  ...
}: let
  vscodePackage = pkgsUnstable.vscode;

  vscodePkgs = pkgs.vscode-marketplace // pkgs.vscode-marketplace-release; # Prefer release over pre-release
in {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager = {
      programs.vscode = {
        enable = true;
        package = vscodePackage;
        profiles.default.extensions = with vscodePkgs; [
          # Remote
          ms-vscode-remote.remote-ssh

          # AI
          github.copilot
          github.copilot-chat

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
}
