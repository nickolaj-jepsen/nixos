{
  flake.modules.nixos.thermald = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.physical {
      # Intel userspace thermal daemon: proactively manages package power/thermal
      # limits (RAPL) before hardware emergency throttling kicks in. All hosts are
      # Intel, so no CPU-vendor gating is needed. Complements the BIOS fan curve.
      services.thermald.enable = true;
    };
  };
}
