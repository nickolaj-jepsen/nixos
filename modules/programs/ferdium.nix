# Ferdium messaging hub — Linux work desktops only (no Mac cask).
{
  flake.modules.homeManager.ferdium = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.work.enable && pkgs.stdenv.isLinux) {
      home.packages = [
        pkgs.unstable.ferdium
      ];
    };
  };
}
