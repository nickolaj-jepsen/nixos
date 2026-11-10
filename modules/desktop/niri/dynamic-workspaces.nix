{inputs, ...}: {
  flake.modules.homeManager.niri-dynamic-workspaces = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Project workspaces: both the spawn programs and ghostty-here's dir lookup
    # come from here, so a bare terminal opens where the workspace points. The
    # editor is `editor-open`, which knows the argv zed and vscode each want.
    workspaces = import ../_workspaces.nix;
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

          workspace =
            {
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
            }
            // lib.mapAttrs (_: w: {inherit (w) name programs;}) workspaces;

          template = {
            dev = {
              programs = [
                "editor-open {{path}}"
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
                "editor-open --remote {{host}}"
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

      # Key -> project dir for ghostty-here. Space-separated, so a project path
      # with whitespace in it would break the lookup.
      xdg.configFile."ghostty-here/dirs".text =
        lib.concatStringsSep "\n"
        (lib.mapAttrsToList (key: w: "${key} ${w.path}") (lib.filterAttrs (_: w: w ? path) workspaces))
        + "\n";
    };
  };
}
