{
  flake.aspectTags.nats = ["dev"];
  # Aspect: dev
  flake.modules.homeManager.nats = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [
        pkgs.unstable.natscli
      ];
    };
  };
}
