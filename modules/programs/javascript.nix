# Aspect: dev
{
  flake.aspectTags.javascript = ["dev"];
  flake.modules.homeManager.javascript = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [
        pkgs.nodejs
        pkgs.unstable.pnpm
        pkgs.turbo-unwrapped
      ];
    };
  };
}
