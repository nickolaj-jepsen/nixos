{
  config,
  lib,
  ...
}: {
  options.fireproof.desktop = {
    enable = lib.mkEnableOption "Enable desktop environment with niri, greetd, and all desktop features";
  };

  imports = [
    ./monitors.nix
    ./audio.nix
    ./fonts.nix
    ./greetd.nix
    ./niri.nix
    ./qt.nix
    ./screenshot.nix
    ./gtk/default.nix
    ./dms/default.nix
  ];

  config = lib.mkIf config.fireproof.desktop.enable {
    # All desktop-related configuration is handled by the individual modules
    # which check for fireproof.desktop.enable
  };
}
