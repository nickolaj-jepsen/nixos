{
  inputs,
  fpLib,
  ...
}: {
  flake.modules.homeManager.niri-dynamic-workspaces = {
    config,
    lib,
    pkgs,
    ...
  }: let
    nixos = fpLib.homePath config "nixos";
    dev = fpLib.homePath config "dev";
    tilt = "${dev}/devenv-tilt";

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
            # mirroring the focus-workspace binds in niri/binds.nix.
            q = {
              static = "01";
              name = "browser";
            };
            w.static = "02";
            e.static = "03";
            r = {
              static = "04";
              name = "music";
            };
            t = {
              static = "05";
              name = "diff";
            };

            n = mkWorkspace {
              name = "nix";
              path = nixos;
            };
            s = mkWorkspace {
              name = "shop";
              path = "${tilt}/projects/vvsshop";
            };
            f = mkWorkspace {
              name = "flex";
              path = "${tilt}/projects/neoflex";
            };
            u = mkWorkspace {
              name = "imagine";
              path = "${tilt}/projects/imagine";
            };
            i = mkWorkspace {
              name = "insight";
              path = "${tilt}/projects/insight";
            };
            p = mkWorkspace {
              name = "producthub";
              path = "${tilt}/projects/producthub";
            };
            l = mkWorkspace {
              name = "python-libs";
              path = "${tilt}/projects/python-libs";
            };
            d = mkWorkspace {
              name = "devenv";
              path = tilt;
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
                  dirs = ["${dev}/" "${tilt}/projects/"];
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
