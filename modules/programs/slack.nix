{
  flake.modules.homeManager.slack = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.work.enable) {
      # darwin installs the cask (below); the nixpkgs build is Linux-only.
      home.packages = lib.optionals pkgs.stdenv.isLinux [
        pkgs.unstable.slack
      ];
    };
  };

  # On darwin the nixpkgs build isn't used; install the Homebrew cask instead.
  flake.modules.darwin.slack = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.work.enable) {
      homebrew.casks = ["slack"];
    };
  };
}
