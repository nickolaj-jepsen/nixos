{
  config,
  lib,
  fpLib,
  ...
}: let
  cfg = config.fireproof.homelab;
  domain = "bitwarden.${cfg.domain}";
in {
  config = lib.mkIf config.fireproof.homelab.enable {
    services = {
      vaultwarden = {
        enable = true;
        config = {
          DOMAIN = "https://${domain}";
          SIGNUPS_ALLOWED = false;
          ROCKET_ADDRESS = "127.0.0.1";
          ROCKET_PORT = 8222;
        };
      };
      restic.backups.homelab = {
        paths = ["/var/lib/vaultwarden"];
        exclude = [
          "/var/lib/vaultwarden/icon_cache"
          "/var/lib/vaultwarden/tmp"
        ];
      };

      nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        host = config.services.vaultwarden.config.ROCKET_ADDRESS;
        port = config.services.vaultwarden.config.ROCKET_PORT;
      };
    };
  };
}
