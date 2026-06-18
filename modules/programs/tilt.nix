{
  flake.modules.homeManager.tilt = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [
        pkgs.unstable.tilt
      ];
    };
  };
}
