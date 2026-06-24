{
  flake.modules.homeManager.vscode-extensions = {
    config,
    lib,
    pkgs,
    ...
  }: let
    vscodePackage = pkgs.unstable.vscode;
    marketplaceReleases = pkgs.vscode-marketplace-release;
  in {
    config = lib.mkIf config.fireproof.vscode.enable {
      programs.vscode = {
        enable = true;
        mutableExtensionsDir = false;
        package = vscodePackage;
        profiles.default.extensions = with pkgs.unstable.vscode-extensions; [
          # Remote
          ms-vscode-remote.remote-ssh

          # Editor
          mkhl.direnv
          usernamehw.errorlens

          # AI
          marketplaceReleases.anthropic.claude-code

          # Git(hub)
          github.vscode-pull-request-github
          github.vscode-github-actions

          # Python
          marketplaceReleases.meta.pyrefly
          ms-python.python
          charliermarsh.ruff

          # JavaScript
          astro-build.astro-vscode
          bradlc.vscode-tailwindcss
          dbaeumer.vscode-eslint
          esbenp.prettier-vscode
          marketplaceReleases.oxc.oxc-vscode
          marketplaceReleases.viijay-kr.react-ts-css
          marketplaceReleases.ms-playwright.playwright
          marketplaceReleases.vitest.explorer
          stylelint.vscode-stylelint
          unifiedjs.vscode-mdx

          # Nix
          jnoortheen.nix-ide

          # Other languages
          nefrob.vscode-just-syntax
          redhat.vscode-yaml
          tamasfe.even-better-toml

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
