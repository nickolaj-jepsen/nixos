{
  flake.modules.nixos.networking = {config, ...}: {
    networking = {
      hostName = config.fireproof.hostname;
    };
  };
}
