{
  flake.modules.homeManager.clickhouse = {pkgs, ...}: {
    config = {
      home.packages = [
        pkgs.unstable.clickhouse
        pkgs.unstable.envsubst
      ];
    };
  };
}
