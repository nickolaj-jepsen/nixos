{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./settings.nix
    ./binds.nix
    ./outputs.nix
  ];

  config = lib.mkIf config.fireproof.desktop.windowManager.enable {
    programs.xwayland.enable = true;

    xdg.portal = {
      enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
      config.common.default = "gnome";
      xdgOpenUsePortal = true;
    };

    programs.niri = {
      enable = true;
      package = inputs.niri.packages."${pkgs.stdenv.hostPlatform.system}".niri-unstable;
    };
  };
}
