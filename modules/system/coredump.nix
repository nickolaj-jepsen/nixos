{
  flake.modules.nixos.coredump = {lib, ...}: {
    # Keep dumps for `coredumpctl debug` (niri-unstable/quickshell crashes) but cap disk use like journald.nix.
    systemd.coredump.settings.Coredump = {
      MaxUse = lib.mkDefault "2G";
      KeepFree = lib.mkDefault "10G";
    };
  };
}
