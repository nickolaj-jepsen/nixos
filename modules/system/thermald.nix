{
  flake.aspectTags.thermald = ["physical"];
  flake.modules.nixos.thermald = _: {
    # Intel userspace thermal daemon: proactively manages package power/thermal
    # limits (RAPL) before hardware emergency throttling kicks in. All hosts are
    # Intel, so no CPU-vendor gating is needed. Complements the BIOS fan curve.
    config = {
      services.thermald.enable = true;
    };
  };
}
