{
  config,
  lib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  domain = "jellyfin.nickolaj.com";
in {
  services.restic.backups.homelab.paths = [config.services.jellyfin.dataDir];

  services.nginx.virtualHosts."${domain}" = {
    forceSSL = true;
    enableACME = true;
    http2 = true;
    locations."/" = {
      proxyWebsockets = true;
      proxyPass = "http://localhost:8096/";
    };
  };

  services.jellyfin = {
    enable = true;
    openFirewall = true;
    user = "media";
    group = "media";
  };
})
