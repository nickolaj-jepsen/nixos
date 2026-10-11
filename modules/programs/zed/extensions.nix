# Zed editor. On darwin the binary is a Homebrew cask and HM manages config only;
# Linux uses the nixpkgs build.
{fpLib, ...}: {
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
  }: let
    languageServers = with pkgs; [
      # Nix
      nil

      # Python
      ruff
      pyrefly

      # JS / TS / JSON / CSS / HTML
      typescript-language-server
      oxfmt
      vscode-langservers-extracted

      # YAML
      yaml-language-server
    ];
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      programs.zed-editor = {
        enable = true;
        package = fpLib.mkDarwinGuiPackage pkgs pkgs.unstable.zed-editor;
        installRemoteServer = true;

        extensions = [
          # Languages
          "nix"
          "just"
          "just-ls"
          "toml"
          "basher"
          "fish"
          "dockerfile"
          "env"
          "biome"
          "css-modules-kit"

          # Python (matches the pyrefly + ruff setup from VSCode)
          "pyrefly"

          # Icons (theme is defined locally in ./theme.nix)
          "seti-icons"

          # Spell / grammar check (replaces cSpell)
          "harper"

          # Context servers
          "mcp-server-linear"
        ];

        extraPackages = lib.optionals pkgs.stdenv.isLinux languageServers;
      };

      # extraPackages wraps the nixpkgs build; the cask can't be wrapped, but Zed
      # loads the login shell's PATH on macOS.
      home.packages = lib.optionals pkgs.stdenv.isDarwin languageServers;
    };
  };
}
