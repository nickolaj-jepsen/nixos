# Enabled when: dev
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.clickhouse.enable {
    fireproof.home-manager.home.packages = [
      pkgs.unstable.clickhouse
      pkgs.unstable.envsubst
    ];
  };
}
