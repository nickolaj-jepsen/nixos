{
  flake.modules.nixos.thermald = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.physical {
      # All hosts are Intel, so no CPU-vendor gating is needed.
      services.thermald.enable = true;
    };
  };
}
