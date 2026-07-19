{
  flake.modules.homeManager.niri-dynamic-workspaces = {
    config,
    lib,
    pkgs,
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
    imports = [
      inputs.niri-dynamic-workspaces.homeModules.default
    ];
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      programs.niri-dynamic-workspaces = {
        enable = true;
        # Pass package explicitly to avoid upstream's `pkgs.system` warning
        # (its default uses the deprecated alias). TODO: fix upstream and drop.
        package = inputs.niri-dynamic-workspaces.packages.${pkgs.stdenv.hostPlatform.system}.default;
        settings = {
          general.hide_empty_static = true;

          workspace = {
            # Pinned to the fixed niri workspaces (Mod+q/w/e/r/t -> "01".."05"),
            # mirroring the compositor binds in the overlay.
            q.static = "01";
            w.static = "02";
            e.static = "03";
            r.static = "04";
            t.static = "05";

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
            y = mkRemoteWorkspace {
              name = "scw-tf";
              host = "dev.ao";
              path = "/home/nij/scw-tf";
            };
          };

          template = {
            dev = {
              programs = [
                "code {{path}}"
                "ghostty --working-directory={{path}}"
              ];
              variables = {
                path = {
                  name = "Path from dev folder";
                  type = "dir";
                  dirs = ["/home/nickolaj/dev/" "/home/nickolaj/dev/devenv-tilt/projects/"];
                };
              };
            };
            remote = {
              programs = [
                "code --remote ssh-remote+{{host}}"
                "ghostty -e ssh -t {{host}}"
              ];
              variables = {
                host = {
                  name = "SSH host";
                  type = "options";
                  options = ["dev.ao" "homelab" "minilab" "desktop" "scw.ao" "staging.ao" "bastion.ao"];
                };
              };
            };
          };
        };
      };
    };
  };
}
