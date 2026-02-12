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

  mkRemoteWorkspace = {
    name,
    host,
    path,
    shell ? "fish",
  }: {
    inherit name;
    programs = [
      "code --remote ssh-remote+${host} ${path}"
      "ghostty -e ssh -t ${host} 'cd ${path} && exec ${shell} -l'"
    ];
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
          u = mkWorkspace {
            name = "imagine";
            path = "/home/nickolaj/dev/devenv-tilt/projects/imagine";
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
          t = mkRemoteWorkspace {
            name = "scw-tf";
            host = "dev.ao";
            path = "/home/nij/scw-tf";
          };
        };

        template = {
          dev = {
            programs = [
              "code /home/nickolaj/dev/{{path}}"
              "ghostty --working-directory=/home/nickolaj/dev/{{path}}"
            ];
            on_create = [
              ''mkdir -p /home/nickolaj/dev/$NDW_VAR_PATH/''
            ];
            variables = {
              path = {
                name = "Path from dev folder";
              };
            };
          };
          remote = {
            programs = [
              "code --remote ssh-remote+{{host}} {{path}}"
              "ghostty -e ssh -t {{host}} 'cd {{path}} && exec fish -l'"
            ];
            variables = {
              host = {
                name = "SSH host";
              };
              path = {
                name = "Remote path";
              };
            };
          };
        };
      };
    };
  };
}
