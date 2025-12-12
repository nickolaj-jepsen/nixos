# Enabled when: desktop & dev
{
  config,
  lib,
  pkgsUnstable,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    environment.systemPackages = [
      pkgsUnstable.sublime-merge
    ];
  };
}
