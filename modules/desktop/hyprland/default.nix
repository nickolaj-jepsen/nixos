{fpLib, ...}: {
  flake.modules.nixos.hyprland = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.hyprland.enable {
      programs.hyprland = {
        enable = true;
        # 0.57 is the Lua-config release; 26.05 ships 0.55.
        package = pkgs.unstable.hyprland;
        portalPackage = pkgs.unstable.xdg-desktop-portal-hyprland;
      };

      # The greeter's picker lists these. Hyprland's package also ships a uwsm session, which
      # nothing here sets up, so only its plain one is offered.
      services.displayManager.sessionPackages = lib.mkForce [
        config.programs.niri.package
        (pkgs.runCommand "hyprland-session" {passthru.providedSessions = ["hyprland"];} ''
          install -Dm444 -t $out/share/wayland-sessions \
            ${config.programs.hyprland.package}/share/wayland-sessions/hyprland.desktop
        '')
      ];

      # Outranks the niri leaf's `common` mapping while XDG_CURRENT_DESKTOP is Hyprland.
      xdg.portal.config.hyprland = {
        default = ["hyprland" "gtk"];
        "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
      };

      # Same VRAM cap as niri gets in the nvidia leaf; the profile itself is defined there.
      environment.etc."nvidia/nvidia-application-profiles-rc.d/51-limit-free-buffer-pool-hyprland.json" = lib.mkIf config.fireproof.hardware.nvidia.enable {
        text = builtins.toJSON {
          rules = [
            {
              pattern = {
                feature = "procname";
                matches = "Hyprland";
              };
              profile = "Limit Free Buffer Pool On Wayland Compositors";
            }
          ];
        };
      };
    };
  };

  flake.modules.homeManager.hyprland = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    hyprland = pkgs.unstable.hyprland;

    # Prints the cwd of the newest shell under the first PID that has one, else the fallback.
    shellCwd = pkgs.writeShellApplication {
      name = "fp-shell-cwd";
      runtimeInputs = [pkgs.procps pkgs.gawk];
      text = ''
        fallback=$1
        shift
        for root in "$@"; do
          dir=$(ps -e -o pid=,ppid=,comm= --sort=-start_time | awk -v root="$root" '
            { parent[$1] = $2; comm[$1] = $3; order[NR] = $1 }
            END {
              for (i = 1; i <= NR; i++) {
                p = order[i]
                if (comm[p] !~ /^(fish|bash|zsh|sh|dash|nu|elvish)$/) continue
                for (q = parent[p]; q > 1; q = parent[q]) if (q == root) { print p; exit }
              }
            }' | while read -r pid; do readlink "/proc/$pid/cwd"; done)
          if [[ -n $dir && -d $dir ]]; then
            echo "$dir"
            exit 0
          fi
        done
        echo "$fallback"
      '';
    };

    fp = {
      colors = {inherit (c) bg fg ui accent black;};
      primary = fpLib.primaryMonitorName config.fireproof.monitors;
      monitors =
        map (m: {
          inherit (m) name enable scale vrr;
          mode =
            if m.resolution.width != null && m.resolution.height != null
            then "${toString m.resolution.width}x${toString m.resolution.height}" + lib.optionalString (m.refreshRateNiri != null) "@${toString m.refreshRateNiri}"
            else "preferred";
          position = "${toString m.position.x}x${toString m.position.y}";
          transform =
            if m.transform == null
            then 0
            else m.transform;
        })
        (lib.filter (m: m.name != null) config.fireproof.monitors);
      workspaces = import ../_workspaces.nix;
      home = config.home.homeDirectory;
      dms_b =
        if config.fireproof.dev.agent-hub.enable
        then "widget toggle agentHub"
        else ''dash toggle ""'';
      bin =
        {
          grim = lib.getExe pkgs.grim;
          slurp = lib.getExe pkgs.slurp;
          wl_copy = lib.getExe' pkgs.wl-clipboard "wl-copy";
          shell_cwd = lib.getExe shellCwd;
        }
        // lib.optionalAttrs config.fireproof.dev.agent-hub.enable {agent_hub = lib.getExe pkgs.agent-hub;};
    };
  in {
    config = lib.mkIf (config.fireproof.desktop.hyprland.enable && pkgs.stdenv.isLinux) {
      wayland.windowManager.hyprland = {
        enable = true;
        # The NixOS half installs both.
        package = null;
        portalPackage = null;
        # A 24.11 stateVersion defaults to hyprlang, which 0.57 no longer reads.
        configType = "lua";
        # niri-session imports the whole login environment; match it.
        systemd.variables = ["--all"];
        extraConfig = "local fp = ${lib.generators.toLua {} fp}\n\n" + builtins.readFile ./config.lua;
      };

      # HM writes this only when it owns the package; it lets lua-language-server check config.lua.
      xdg.configFile."hypr/.luarc.json".text = builtins.toJSON {
        workspace.library = ["${hyprland}/share/hypr/stubs"];
        diagnostics.globals = ["hl" "fp" "fp_api"];
      };
    };
  };
}
