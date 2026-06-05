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
}
