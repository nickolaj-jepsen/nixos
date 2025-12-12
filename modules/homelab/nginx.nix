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
  };
  security.acme = {
    acceptTerms = true;
    defaults.email = "nickolaj@fireproof.website";
  };
}
