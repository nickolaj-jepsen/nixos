{
  flake.modules.nixos.coredump = {
    config,
    lib,
    ...
  }: {
    # Keep dumps for `coredumpctl debug` (niri-unstable/quickshell crashes) but cap disk use.
    systemd.coredump.settings.Coredump = {
      # A pocketnix guest's module caps it to what fits on a phone.
      MaxUse = lib.mkIf (!config.fireproof.pocketnix.enable) (lib.mkDefault "2G");
      KeepFree = lib.mkDefault "10G";
      # MaxUse skips the dump just written, so one huge core (llama-server's ~15G) evicts all the others.
      ProcessSizeMax = lib.mkDefault "1G";
      ExternalSizeMax = lib.mkDefault "1G";
    };
  };
}
