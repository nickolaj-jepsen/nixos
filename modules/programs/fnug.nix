{
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
