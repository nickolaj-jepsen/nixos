# Enabled when: desktop
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager.home.packages = [
      pkgs.unstable.obsidian
    ];
  };
}
