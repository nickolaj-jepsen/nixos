# Enabled when: desktop & dev
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    environment.systemPackages = [
      pkgs.unstable.sublime-merge
    ];
  };
}
