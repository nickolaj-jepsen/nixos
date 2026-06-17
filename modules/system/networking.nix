{
  flake.aspectTags.networking = ["base"];
  flake.modules.nixos.networking = {config, ...}: {
    networking = {
      hostName = config.fireproof.hostname;
    };
  };
}
