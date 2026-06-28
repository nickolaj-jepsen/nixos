{
  flake.modules.homeManager.slack = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.work.enable) {
      home.packages = [
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
    config = lib.mkIf config.fireproof.slack.enable {
      homebrew.casks = ["slack"];
    };
  };
}
