# Enabled when: dev
{
  config,
  lib,
  pkgsUnstable,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.clickhouse.enable {
    environment.systemPackages = [
      pkgsUnstable.clickhouse
      pkgsUnstable.envsubst
    ];
  };
}
