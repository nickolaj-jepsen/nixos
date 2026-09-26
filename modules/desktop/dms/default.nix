{inputs, ...}: {
  flake.modules.nixos.dms = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      systemd.user.services.niri-flake-polkit.enable = false;
    };
  };

  flake.modules.homeManager.dms = {
    config,
    lib,
    pkgs,
    ...
  }: let
    jq = lib.getExe pkgs.jq;
    jsonFormat = pkgs.formats.json {};
    # session.json is DMS's runtime state (wallpaper, night mode, …), so it stays writable instead of
    # using `programs.dank-material-shell.session`: enforced keys win on every switch, defaults only fill gaps.
    sessionEnforced = jsonFormat.generate "dms-session-enforced.json" {
      weatherCoordinates = "56.1496278,10.2134046";
    };
    sessionDefaults = jsonFormat.generate "dms-session-defaults.json" {
      wallpaperPath = "${config.xdg.dataHome}/backgrounds/unknown.png";
    };
  in {
    imports = [
      inputs.dank-material-shell.homeModules.dank-material-shell
    ];
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      programs.dank-material-shell = {
        enable = true;

        enableDynamicTheming = false;
        # DMS VPN only drives NetworkManager connections.
        enableVPN = config.fireproof.hardware.wifi;
        enableCalendarEvents = false;
        quickshell.package = pkgs.unstable.quickshell; # dms 1.5-beta needs quickshell >= 0.3.0 for `pragma AppId`

        systemd.enable = true;

        settings = {
          # Must match SettingsData.qml schema version, else a per-start migration runs silently; re-pin after `just update`.
          configVersion = 16;

          # Enable blur on DMS's layer-shell surfaces. Blur only shows through
          # translucency, so popupTransparency must be < 1 — the default 1.0 is solid
          # and hides it entirely.
          blurEnabled = true;
          popupTransparency = 0.46;
          # DMS outlines every blurred surface by default; the outline fights the
          # near-black palette, so drop it (blurBorderColor/Opacity are then dead keys).
          blurBorderEnabled = false;

          clockFormat = "24h";
          clockDateFormat = "yyyy-MM-dd";
          firstDayOfWeek = 1; # Monday; -1 means "follow locale"
          showWeekNumber = true;

          loginctlLockIntegration = true;
          fadeToLockEnabled = true;
          fadeToLockGracePeriod = 5;

          acMonitorTimeout = 1800;
          acLockTimeout = 600;
          acSuspendTimeout = 0;
          batteryMonitorTimeout = 600;
          batteryLockTimeout = 300;
          batterySuspendTimeout = 1800;

          powerMenuActions = [
            "reboot"
            "logout"
            "poweroff"
            "lock"
            "suspend"
          ];
          powerMenuDefaultAction = "lock";
        };
      };

      # niri defaults blur to xray (blurs the wallpaper — near-black here, so popouts
      # look solid); force xray off so DMS's layers blur the windows behind them.
      # niri-flake can't express background-effect, so append the rule and re-validate
      # against niri-unstable (its default niri-stable predates it, would reject it).
      xdg.configFile.niri-config.source = lib.mkForce (
        pkgs.runCommand "niri-config.kdl" {
          config =
            config.programs.niri.finalConfig
            + ''

              layer-rule {
                  match namespace="^dms:"
                  background-effect {
                      xray false
                  }
              }
            '';
          passAsFile = ["config"];
          buildInputs = [pkgs.niri-unstable];
        } ''
          niri validate -c $configPath
          cp $configPath $out
        ''
      );

      home.activation.dmsSession = lib.hm.dag.entryAfter ["linkGeneration"] ''
        file=${config.xdg.stateHome}/DankMaterialShell/session.json
        old='{}'
        # A leftover HM store symlink holds Nix values, not user choices.
        if [ -f "$file" ] && [ ! -L "$file" ]; then
          old=$(${jq} -c 'objects' "$file" 2>/dev/null) && [ -n "$old" ] || old='{}'
        fi
        new=$(${jq} -s --argjson old "$old" '.[0] * $old * .[1]' ${sessionDefaults} ${sessionEnforced})
        run mkdir -p "$(dirname "$file")"
        run rm -f "$file"
        run install -m644 /dev/stdin "$file" <<<"$new"
      '';
    };
  };
}
