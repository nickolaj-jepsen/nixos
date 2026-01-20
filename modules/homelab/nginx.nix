{
  config,
  lib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable {
  networking.firewall.allowedTCPPorts = [80 443];

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedGzipSettings = true;
    recommendedBrotliSettings = true;

    virtualHosts."status.localhost" = {
      listen = [{ addr = "127.0.0.1"; port = 8070; }];
      locations."/metrics" = {
        extraConfig = ''
          stub_status;
          access_log off;
          allow 127.0.0.1;
          allow ::1;
          deny all;
        '';
      };
    };
  };
  security.acme = {
    acceptTerms = true;
    defaults.email = "nickolaj@fireproof.website";
  };
}
