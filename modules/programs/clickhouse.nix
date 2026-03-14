# Enabled when: dev
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.clickhouse.enable {
    environment.systemPackages = [
      pkgs.unstable.clickhouse
      pkgs.unstable.envsubst
    ];
  };
}
