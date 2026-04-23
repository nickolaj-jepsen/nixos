{
  config,
  lib,
  pkgs,
  ...
}: let
  vscodePackage = pkgs.unstable.vscode;
  marketplaceReleases = pkgs.vscode-marketplace-release;
in {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager = {
      programs.vscode = {
        enable = true;
        mutableExtensionsDir = false;
        package = vscodePackage;
        profiles.default.extensions = with pkgs.unstable.vscode-extensions; [
          # Remote
          ms-vscode-remote.remote-ssh

          # AI
          marketplaceReleases.anthropic.claude-code
          github.copilot-chat

          # Git(hub)
          github.vscode-pull-request-github

          # Python
          marketplaceReleases.meta.pyrefly
          ms-pyright.pyright
          ms-python.python
          charliermarsh.ruff

          # JavaScript
          dbaeumer.vscode-eslint
          esbenp.prettier-vscode
          marketplaceReleases.oxc.oxc-vscode
          marketplaceReleases.viijay-kr.react-ts-css
          marketplaceReleases.ms-playwright.playwright
          marketplaceReleases.vitest.explorer
          stylelint.vscode-stylelint

          # Nix
          jnoortheen.nix-ide

          # Other languages
          nefrob.vscode-just-syntax
          redhat.vscode-yaml

          # Spell checking
          streetsidesoftware.code-spell-checker
          marketplaceReleases.streetsidesoftware.code-spell-checker-danish

          # Theme
          marketplaceReleases.trinm1709.dracula-theme-from-intellij

          # Keybindings
          k--kato.intellij-idea-keybindings
        ];
      };
    };
  };
}
