{
  flake.modules.nixos.tailscale = _: {
    services.tailscale.enable = true;
  };
}
