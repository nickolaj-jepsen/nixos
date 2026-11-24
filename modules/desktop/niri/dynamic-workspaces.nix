{inputs, ...}: {
  flake.modules.homeManager.niri-dynamic-workspaces = {
    config,
    lib,
    pkgs,
    ...
  }: let
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
            // lib.mapAttrs (_: w: {template = w.name;}) workspaces;

          template =
            {
              dev = {
                programs = [
                  "editor-open {{path}}"
                  "kitty --directory={{path}}"
                ];
                # Recorded so umbriel-workspace-kitty opens in the project.
                cwd = "{{path}}";
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
                  "kitty -- ssh -t {{host}}"
                ];
                variables = {
                  host = {
                    name = "SSH host";
                    type = "options";
                    options = ["dev.ao" "homelab" "minilab" "desktop" "scw.ao" "staging.ao" "bastion.ao"];
                  };
                };
              };
            }
            // lib.listToAttrs (lib.mapAttrsToList (_: w: lib.nameValuePair w.name w.template) workspaces);
        };
      };

      # Part of the shell: beside niri in session.slice. Its programs are spawned through niri,
      # so they still land in app.slice scopes.
      systemd.user.services.niri-dynamic-workspaces = {
        Service.Slice = "session.slice";
        # A warm daemon opens the overlay in ~90 ms against ~350 ms for a cold GTK start, so run it
        # in umbriel sessions too (umbriel exports UMBRIEL_SOCKET before graphical-session.target).
        Unit.ConditionEnvironment = lib.mkForce ["|NIRI_SOCKET" "|UMBRIEL_SOCKET"];
        # The include umbriel.service creates (modules/desktop/umbriel); unused under niri.
        Service.Environment = ["NDW_UMBRIEL_INCLUDE=%t/ndw-umbriel/workspaces.toml"];
      };
    };
  };
}
