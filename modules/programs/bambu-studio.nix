{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.bambu-studio.enable) {
    fireproof.home-manager.home.packages = [
      pkgs.bambu-studio
    ];
  };
}
