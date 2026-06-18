{
  flake.modules.homeManager.emdash = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [pkgs.emdash];
    };
  };
}
