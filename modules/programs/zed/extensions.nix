# Zed editor. On darwin a Homebrew cask (HM-managed settings/extensions/theme are
# Linux-only — the HM module pins the nixpkgs build); Linux uses the nixpkgs build.
{
  flake.modules.darwin.zed-editor = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      homebrew.casks = ["zed"];
    };
  };

  flake.modules.homeManager.zed-extensions = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable && pkgs.stdenv.isLinux) {
      programs.zed-editor = {
        enable = true;
        package = pkgs.unstable.zed-editor;
        installRemoteServer = true;

        extensions = [
          # Languages
          "nix"
          "just"
          "toml"
          "basher"

          # Python (matches the pyrefly + ruff setup from VSCode)
          "pyrefly"

          # Icons (theme is defined locally in ./theme.nix)
          "seti-icons"

          # Spell / grammar check (replaces cSpell)
          "harper"
        ];

        extraPackages = with pkgs; [
          # Nix
          nil

          # Python
          ruff
          pyrefly

          # JS / TS / JSON / CSS / HTML
          typescript-language-server
          prettier
          vscode-langservers-extracted

          # YAML
          yaml-language-server
        ];
      };
    };
  };
}
