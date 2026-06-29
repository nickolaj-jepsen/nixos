{
  flake.modules.nixos.tailscale = _: {
    services.tailscale.enable = true;
    networking.firewall.trustedInterfaces = ["tailscale0"];
  };

  # macOS counterpart: the GUI client as a Homebrew cask (the standalone build,
  # not the sandboxed Mac App Store one). Ungated to match the always-on NixOS
  # half — Tailscale runs fleet-wide.
  flake.modules.darwin.tailscale = _: {
    homebrew.casks = ["tailscale-app"];
  };
}
