{
  flake.modules.homeManager.postgres-cli = {pkgs, ...}: {
    config = {
      home.packages = [
        pkgs.postgresql
      ];
    };
  };
}
