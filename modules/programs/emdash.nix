{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    fireproof.home-manager.home.packages = [pkgs.emdash];
  };
}
