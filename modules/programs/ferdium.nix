# Enabled when: desktop & work
{
  config,
  lib,
  pkgsUnstable,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.work.enable) {
    environment.systemPackages = [
      pkgsUnstable.ferdium
    ];
  };
}
