# Enabled when: desktop
{
  config,
  lib,
  pkgsUnstable,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    environment.systemPackages = [
      pkgsUnstable.obsidian
    ];
  };
}
