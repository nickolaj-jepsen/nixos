# Opt-in systemd-networkd. Not universal — laptop uses NetworkManager and the
# WSL/minilab hosts manage networking elsewhere — so it's an aspect a host
# selects, not a base default.
{
  flake.modules.nixos.networkd = {
    systemd.network.enable = true;
    networking.useNetworkd = true;
  };
}
