# Opt-in: laptop uses NetworkManager, WSL/minilab manage networking elsewhere.
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
