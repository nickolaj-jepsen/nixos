{
  flake.modules.nixos.tailscale = {
    config,
    lib,
    ...
  }: let
    cfg = config.fireproof.tailscale;
  in {
    config = lib.mkIf cfg.enable {
      age.secrets = lib.mkIf cfg.autoLogin {
        tailscale-authkey.rekeyFile = ../../secrets/tailscale-authkey.age;
      };

      services.tailscale = {
        enable = true;
        extraSetFlags = ["--operator=${config.fireproof.username}"];
        # The key is an OAuth client secret (never expires) — it must tag the node,
        # and tagged nodes have no key expiry, so enrolment is set-and-forget.
        authKeyFile = lib.mkIf cfg.autoLogin config.age.secrets.tailscale-authkey.path;
        extraUpFlags = lib.mkIf cfg.autoLogin ["--advertise-tags=tag:fireproof"];
      };

      # Manual-login hosts may be pointed at a tailnet other than the personal
      # one, so only auto-enrolled hosts trust the interface.
      networking.firewall.trustedInterfaces = lib.mkIf cfg.autoLogin ["tailscale0"];
    };
  };

  # macOS counterpart: the GUI client as a Homebrew cask (the standalone build,
  # not the sandboxed Mac App Store one). Ungated — the Mac logs in by hand, so
  # there is no auth-key hook to gate on.
  flake.modules.darwin.tailscale = _: {
    homebrew.casks = ["tailscale-app"];
  };
}
