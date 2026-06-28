{
  flake.modules.homeManager.obsidian = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      # darwin installs the cask (below); the nixpkgs build is Linux-only.
      home.packages = lib.optionals pkgs.stdenv.isLinux [
        pkgs.unstable.obsidian
      ];
    };
  };

  # On darwin the nixpkgs build isn't used; install the Homebrew cask instead.
  # Vault config lives inside each vault folder, so there's no HM config to manage.
  flake.modules.darwin.obsidian = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["obsidian"];
    };
  };
}
