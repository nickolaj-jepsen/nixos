# Enabled when: desktop & dev
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager.home.packages = [
      pkgs.unstable.sublime-merge
    ];
  };
}
