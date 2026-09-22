{
  flake.modules.nixos.coredump = {lib, ...}: {
    # Keep dumps for `coredumpctl debug` (niri-unstable/quickshell crashes) but cap disk use like journald.nix.
    systemd.coredump.settings.Coredump = {
      MaxUse = lib.mkDefault "2G";
      KeepFree = lib.mkDefault "10G";
      # MaxUse skips the dump just written, so one huge core (llama-server's ~15G) evicts all the others.
      ProcessSizeMax = lib.mkDefault "1G";
      ExternalSizeMax = lib.mkDefault "1G";
    };
  };
}
