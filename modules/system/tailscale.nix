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
        extraSetFlags =
          ["--operator=${config.fireproof.username}"]
          # ts-input's 100.64.0.0/10 anti-spoof drop eats sshuttle's REDIRECT replies on lo
          ++ lib.optional config.fireproof.scripts.tunnel-home.enable "--netfilter-mode=nodivert";
        # The key is an OAuth client secret (never expires) — it must tag the node,
        # and tagged nodes have no key expiry, so enrolment is set-and-forget.
        authKeyFile = lib.mkIf cfg.autoLogin config.age.secrets.tailscale-authkey.path;
        # --reset because `tailscale up` refuses to run while a non-default pref it
        # doesn't mention is set, and the --operator above is exactly that (it lands
        # in prefs via `tailscale set`, which re-runs after autoconnect anyway).
        extraUpFlags = lib.mkIf cfg.autoLogin ["--reset" "--advertise-tags=tag:fireproof"];
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
