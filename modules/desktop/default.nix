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
  };

  imports = [
    ./clipboard.nix
    ./monitors.nix
    ./audio.nix
    ./snapcast.nix
    ./0xcb-media.nix
    ./fonts.nix
    ./greetd.nix
    ./niri
    ./nvidia.nix
    ./qt.nix
    ./gtk.nix
    ./default-apps.nix
    ./dms/default.nix
  ];
}
