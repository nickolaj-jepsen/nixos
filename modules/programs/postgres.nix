{
  flake.aspectTags.postgres-cli = ["dev"];
  # Aspect: dev
  flake.modules.homeManager.postgres-cli = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [
        pkgs.postgresql
      ];
    };
  };
}
