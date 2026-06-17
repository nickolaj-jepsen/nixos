# Aspect: dev
{
  flake.aspectTags.fnug = ["dev"];
  flake.modules.homeManager.fnug = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [pkgs.fnug];
    };
  };
}
