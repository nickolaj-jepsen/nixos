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

  # I can't get nix-vscode-extensions to respect allowUnfree, so this is a workaround
  allowUnfree = ext: ext.override {meta.license = [];};
in {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager = {
      programs.vscode = {
        enable = true;
        package = vscodePackage;
        profiles.default.extensions = with vscodePkgs; [
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
}
