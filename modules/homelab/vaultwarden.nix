{fpLib, ...}: {
  flake.modules.nixos.vaultwarden = {
    config,
    lib,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "bitwarden.${cfg.domain}";
    inherit (config.services.vaultwarden) backupDir;
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      services = {
        vaultwarden = {
          enable = true;
          # sqlite3 .backup snapshot; restic must not copy the live WAL-mode DB.
          backupDir = "/var/backup/vaultwarden";
          config = {
            DOMAIN = "https://${domain}";
            SIGNUPS_ALLOWED = false;
            ROCKET_ADDRESS = "127.0.0.1";
            ROCKET_PORT = 8222;
          };
        };
        restic.backups.homelab = {
          paths = [backupDir];
          exclude = [
            "${backupDir}/icon_cache"
            "${backupDir}/tmp"
          ];
        };

        nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
          host = config.services.vaultwarden.config.ROCKET_ADDRESS;
          port = config.services.vaultwarden.config.ROCKET_PORT;
          websockets = true;
          # Bitwarden's 500 MB attachment/Send cap plus overhead.
          extraConfig = ''
            client_max_body_size 525M;
          '';
        };
      };

      # Snapshot right before restic reads it instead of on the module's own 23:00 timer.
      systemd.services.restic-backups-homelab = {
        wants = ["backup-vaultwarden.service"];
        after = ["backup-vaultwarden.service"];
      };
      systemd.timers.backup-vaultwarden.enable = false;
    };
  };
}
