# Opt-in: not for hosts on NetworkManager or whose networking is managed outside NixOS.
{
  flake.modules.nixos.networkd = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.networkd.enable {
      systemd.network.enable = true;
      networking.useNetworkd = true;
    };
  };
}
