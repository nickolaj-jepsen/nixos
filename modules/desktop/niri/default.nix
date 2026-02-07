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
    home-manager.sharedModules = [
      inputs.niri-dynamic-workspaces.homeModules.default
    ];

    programs.xwayland.enable = true;

    xdg.portal = {
      enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
      config.common.default = "gnome";
      xdgOpenUsePortal = true;
    };

    programs.niri = {
      enable = true;
      package = pkgs.niri-unstable;
    };

    fireproof.home-manager.programs.niri-dynamic-workspaces = {
      enable = true;
    };
  };
}
