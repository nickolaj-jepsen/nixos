{
  flake.modules.homeManager.clickhouse = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.clickhouse.enable {
      home.packages = [
        # Stable: unstable's clickhouse often lags on Hydra, and a source build blows CI's 2h timeout.
        pkgs.clickhouse
        pkgs.unstable.envsubst
      ];
    };
  };
}
