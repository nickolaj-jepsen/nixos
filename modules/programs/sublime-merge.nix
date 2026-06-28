{
  # darwin installs the cask; Linux installs the nixpkgs build (HM half below).
  flake.modules.darwin.sublime-merge = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      homebrew.casks = ["sublime-merge"];
    };
  };

  flake.modules.homeManager.sublime-merge = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      # darwin installs the cask (below); the nixpkgs build is Linux-only.
      home.packages = lib.optionals pkgs.stdenv.isLinux [
        pkgs.unstable.sublime-merge
      ];
    };
  };
}
