# Enabled when: desktop & work
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.work.enable) {
    fireproof.home-manager.home.packages = [
      pkgs.unstable.ferdium
    ];
  };
}
