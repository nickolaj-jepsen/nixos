# Headless: nobody is at the console to answer an emergency shell or power-cycle a hang.
{
  flake.modules.nixos.homelab-resilience = {
    config,
    lib,
    ...
  }: let
    # Includes arr/jellyfin/plex, whose /mnt/data paths are set in their UIs.
    poolUnits = [
      "audiobookshelf"
      "bazarr"
      "docker-grimmory"
      "docker-romm"
      "jellyfin"
      "lidarr"
      "navidrome"
      "plex"
      "qbittorrent"
      "radarr"
      "sabnzbd"
      "shelfmark"
      "sonarr"
    ];
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      # Root has no password: the emergency shell is a dead end that keeps sshd from starting.
      systemd.enableEmergencyMode = false;

      # Booting past a failed mount would otherwise run these against an empty dir on the root fs.
      systemd.services = lib.genAttrs poolUnits (_: {
        unitConfig.RequiresMountsFor = ["/mnt/data"];
      });

      systemd.settings.Manager = {
        RuntimeWatchdogSec = "30s";
        RebootWatchdogSec = "10min";
      };
      boot.kernel.sysctl."kernel.panic" = 10; # seconds until reboot
    };
  };
}
