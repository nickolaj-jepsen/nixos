{config, ...}: let
  domain = "bitwarden.nickolaj.com";
in {
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

    nginx.virtualHosts."${domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://${toString config.services.vaultwarden.config.ROCKET_ADDRESS}:${toString config.services.vaultwarden.config.ROCKET_PORT}";
      };
    };
  };
}
