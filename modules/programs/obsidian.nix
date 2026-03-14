# Enabled when: desktop
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    environment.systemPackages = [
      pkgs.unstable.obsidian
    ];
  };
}
