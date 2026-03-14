# Enabled when: desktop & work
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.work.enable) {
    environment.systemPackages = [
      pkgs.unstable.slack
    ];
  };
}
