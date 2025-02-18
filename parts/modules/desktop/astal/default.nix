{
  inputs,
  pkgs,
  lib,
  config,
  ...
}: let
  packageName = "fireproof-shell";
  cfg = config.modules.astral;
  package = inputs.ags.lib.bundle {
    inherit pkgs;
    src = ./.;
    name = packageName;
    gtk4 = true;
    entry = "app.ts";
    extraPackages = with inputs.ags.packages.${pkgs.system}; [
      battery
      bluetooth
      hyprland
      network
      tray
      notifd
      mpris
      wireplumber
    ];
  };
in {
  options = {
    modules.astral.primaryMonitor = lib.mkOption {
      type = lib.types.string;
      default = "";
      example = "M27Q";
    };
    modules.astral.notificationIgnores = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["/^Spotify/"];
      example = ["/^Spotify/"];
    };
    modules.astral.trayIgnore = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["/spotify/"];
      example = ["/spotify/"];
    };
  };

  config = {
  environment.systemPackages = [package inputs.ags.packages.${pkgs.system}.agsFull];

  fireproof.home-manager = {
    systemd.user.services.astal = {
      Unit = {
        Description = "Astal";
        Documentation = "https://github.com/Aylur/astal";
        After = ["graphical-session.target"];
      };

      Service = {
        ExecStart = "${package}/bin/${packageName}";
        Restart = "on-failure";
        KillMode = "mixed";
        Slice = "app-graphical.slice";
        DefaultEnvironment = ''
          ASTRAL_PRIMARY_MONITOR=${cfg.primaryMonitor}
          ASTRAL_NOTIFICATION_IGNORE=${lib.concatStringsSep "," cfg.notificationIgnores}
          ASTRAL_TRAY_IGNORE=${lib.concatStringsSep "," cfg.trayIgnore}
          '';
      };

      Install = {
        WantedBy = ["graphical-session.target"];
      };
    };
  };
};
}