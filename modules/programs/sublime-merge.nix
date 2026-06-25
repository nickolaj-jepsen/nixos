{
  # darwin has no desktop.enable; gate the cask on dev.enable (its natural analog
  # on a Mac, which is always a GUI host). Linux installs the nixpkgs build below.
  flake.modules.darwin.sublime-merge = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
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
      home.packages = [
        pkgs.unstable.sublime-merge
      ];
    };
  };
}
