# Aspect: homelab — shared homelab facts (domain/email), read by the services.
{
  flake.aspectTags.homelab-options = ["homelab"];

  flake.modules.nixos.homelab-options = {lib, ...}: {
    options.fireproof.homelab = {
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
  };
}
