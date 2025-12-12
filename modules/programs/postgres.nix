# Enabled when: dev
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    environment.systemPackages = [
      pkgs.postgresql
    ];
  };
}
