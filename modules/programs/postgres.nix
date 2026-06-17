{
  flake.aspectTags.postgres-cli = ["dev"];
  # Aspect: dev
  flake.modules.homeManager.postgres-cli = {
    pkgs,
    ...
  }: {
    config = {
      home.packages = [
        pkgs.postgresql
      ];
    };
  };
}
