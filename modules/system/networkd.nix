# Opt-in systemd-networkd. Not universal — laptop uses NetworkManager and the
# WSL/minilab hosts manage networking elsewhere — so it's a toggle a host
# enables, not a base default.
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
