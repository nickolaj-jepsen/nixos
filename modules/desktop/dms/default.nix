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
    wallpaper = dir: "${config.xdg.dataHome}/${dir}/dither-moon.png";
    # Odd transforms are 90°/270° (niri-outputs multiplies by 90).
    portraitMonitors = lib.filter (m: m.name != null && m.transform != null && lib.mod m.transform 2 == 1) config.fireproof.monitors;
    sessionDefaults = jsonFormat.generate "dms-session-defaults.json" ({
        wallpaperPath = wallpaper "backgrounds";
      }
      // lib.optionalAttrs (portraitMonitors != []) {
        perMonitorWallpaper = true;
        # Unlisted monitors fall back to wallpaperPath.
        monitorWallpapers = lib.genAttrs (map (m: m.name) portraitMonitors) (_: wallpaper "backgrounds-portrait");
      });
  in {
    imports = [
      inputs.dank-material-shell.homeModules.dank-material-shell
    ];
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      programs.dank-material-shell = {
        enable = true;

        # Lock-screen wallpaper blur is a hardcoded Theme constant with no setting.
        package = inputs.dank-material-shell.packages.${pkgs.stdenv.hostPlatform.system}.dms-shell.overrideAttrs (old: {
          postInstall =
            (old.postInstall or "")
            + ''
              substituteInPlace $out/share/quickshell/dms/Common/Theme.qml \
                --replace-fail "lockScreenBlur: 0.8" "lockScreenBlur: 0"
            '';
        });

        enableDynamicTheming = false;
        # DMS VPN only drives NetworkManager connections.
        enableVPN = config.fireproof.hardware.wifi;
        enableCalendarEvents = false;
        quickshell.package = pkgs.unstable.quickshell; # dms 1.5-beta needs quickshell >= 0.3.0 for `pragma AppId`

        systemd.enable = true;

        settings = {
          # Must match SettingsData.qml schema version, else a per-start migration runs silently; re-pin after `just update`.
          configVersion = 16;

          # Blur only shows through translucency; the default popupTransparency of 1 hides it.
          blurEnabled = true;
          popupTransparency = 0.46;
          # The default outline on blurred surfaces fights the near-black palette.
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

      # niri's default xray blur only shows the near-black wallpaper; blur the windows behind DMS instead.
      # niri-flake can't express background-effect, and its niri-stable validator predates it.
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
