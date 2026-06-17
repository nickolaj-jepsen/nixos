{
  # base, not homelab: base/nix.nix reads fireproof.homelab.domain (attic
  # substituter) on every host, so these facts must be declared everywhere.
  flake.aspectTags.homelab-options = ["base"];

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
