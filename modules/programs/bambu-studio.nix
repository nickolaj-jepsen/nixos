{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.bambu-studio.enable) {
    environment.systemPackages = [
      pkgs.bambu-studio
    ];
  };
}
