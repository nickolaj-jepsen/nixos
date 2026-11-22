{
  flake.modules.homeManager.javascript = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [
        pkgs.unstable.nodejs
        pkgs.unstable.pnpm
        pkgs.unstable.turbo
      ];
    };
  };
}
