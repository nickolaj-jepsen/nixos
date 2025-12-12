{
  config,
  pkgsUnstable,
  lib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  domain = "plex.nickolaj.com";
in {
  services.nginx.virtualHosts."${domain}" = {
    forceSSL = true;
    enableACME = true;
    http2 = true;
    locations."/" = {
      proxyWebsockets = true;
      proxyPass = "http://localhost:32400/";
    };
  };

  services.plex = {
    enable = true;
    package = pkgsUnstable.plex;
    openFirewall = true;
    user = "media";
    group = "media";
  };
})
