{lib, ...}: {
  options.fireproof.homelab = {
    enable = lib.mkEnableOption "Enable homelab services (arr, nginx, postgres, prometheus, etc.)";
    domain = lib.mkOption {
      type = lib.types.str;
      default = "nickolaj.com";
      description = "Root domain used for homelab service hostnames.";
    };
    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "nickolaj@fireproof.website";
      description = "Contact email registered with the ACME provider.";
    };
  };
}
