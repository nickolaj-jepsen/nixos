{
  config,
  lib,
  inputs,
  ...
}: let
  mkWorkspace = {
    name,
    path,
    programs ? ["code ${path}" "ghostty --working-directory=${path}"],
  }: {
    inherit name programs;
  };
in {
  config = lib.mkIf config.fireproof.desktop.windowManager.enable {
    home-manager.sharedModules = [
      inputs.niri-dynamic-workspaces.homeModules.default
    ];

    fireproof.home-manager.programs.niri-dynamic-workspaces = {
      enable = true;
      settings = {
        workspace = {
          n = mkWorkspace {
            name = "nix";
            path = "/home/nickolaj/nixos";
          };
          s = mkWorkspace {
            name = "shop";
            path = "/home/nickolaj/dev/devenv-tilt/projects/vvsshop";
          };
          f = mkWorkspace {
            name = "flex";
            path = "/home/nickolaj/dev/devenv-tilt/projects/neoflex";
          };
          i = mkWorkspace {
            name = "insight";
            path = "/home/nickolaj/dev/devenv-tilt/projects/insight";
          };
          r = mkWorkspace {
            name = "reviews";
            path = "/home/nickolaj/dev/devenv-tilt/projects/reviews";
          };
          p = mkWorkspace {
            name = "producthub";
            path = "/home/nickolaj/dev/devenv-tilt/projects/producthub";
          };
          l = mkWorkspace {
            name = "python-libs";
            path = "/home/nickolaj/dev/devenv-tilt/projects/python-libs";
          };
          d = mkWorkspace {
            name = "devenv";
            path = "/home/nickolaj/dev/devenv-tilt";
          };
        };
      };
    };
  };
}
