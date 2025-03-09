_: {
  networking.firewall.allowedTCPPorts = [80 443];

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
  };
  security.acme = {
    acceptTerms = true;
    defaults.email = "nickolaj@fireproof.website";
  };
}
