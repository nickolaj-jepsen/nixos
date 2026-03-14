{
  config,
  lib,
  pkgs,
  ...
}: {
  options.fireproof.desktop.bambu-studio.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable Bambu Studio 3D printing slicer";
  };

  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.bambu-studio.enable) {
    environment.systemPackages = [
      pkgs.bambu-studio
    ];
  };
}
