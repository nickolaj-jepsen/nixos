{
  flake.aspectTags.clickhouse = ["clickhouse"];
  flake.modules.homeManager.clickhouse = {
    pkgs,
    ...
  }: {
    config = {
      home.packages = [
        pkgs.unstable.clickhouse
        pkgs.unstable.envsubst
      ];
    };
  };
}
