{
  flake.aspectTags.tailscale = ["base"];
  flake.modules.nixos.tailscale = _: {
    services.tailscale.enable = true;
  };
}
