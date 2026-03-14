{
  config,
  lib,
  fpLib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable {
  services.restic.backups.homelab.paths = ["/var/lib/scrutiny"];

  services.scrutiny = {
    enable = true;
    collector.enable = true;
    settings = {
      web.listen.port = 8089;
    };
  };

  services.oauth2-proxy.nginx.virtualHosts."scrutiny.nickolaj.com".allowed_groups = ["admin"];

  services.nginx.virtualHosts."scrutiny.nickolaj.com" = fpLib.mkVirtualHost {
    port = 8089;
  };
}
