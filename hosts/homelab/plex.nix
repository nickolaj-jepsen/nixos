_: let
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
    openFirewall = true;
    user = "media";
    group = "media";
  };
}
