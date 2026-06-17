{
  flake.aspectTags.clickhouse = ["clickhouse"];
  flake.modules.homeManager.clickhouse = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.clickhouse.enable {
      home.packages = [
        pkgs.unstable.clickhouse
        pkgs.unstable.envsubst
      ];
    };
  };
}
