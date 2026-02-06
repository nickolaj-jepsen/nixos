{
  config,
  lib,
  ...
}: {
  options.fireproof.desktop = {
    enable = lib.mkEnableOption "Enable desktop environment with niri, greetd, and all desktop features";
    windowManager.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.fireproof.desktop.enable;
      description = "Enable window manager (niri) and dank material shell (dms)";
    };
    chromium.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.fireproof.desktop.enable;
      description = "Enable Chromium";
    };
    zed.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.fireproof.desktop.enable;
      description = "Enable Zed editor";
    };
    bambu-studio.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Bambu Studio 3D printing slicer";
    };
  };

  imports = [
    ./clipboard.nix
    ./monitors.nix
    ./audio.nix
    ./fonts.nix
    ./greetd.nix
    ./niri
    ./qt.nix
    ./gtk.nix
    ./dms/default.nix
  ];
}
