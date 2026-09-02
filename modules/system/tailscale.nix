{
  flake.modules.nixos.tailscale = {
    config,
    lib,
    pkgs,
    ...
  }: {
    age.secrets.tailscale-authkey.rekeyFile = ../../secrets/tailscale-authkey.age;

    services.tailscale = {
      enable = true;
      authKeyFile = config.age.secrets.tailscale-authkey.path;
      # The key is an OAuth client secret (never expires) — it must tag the node,
      # and tagged nodes have no key expiry, so enrolment is set-and-forget.
      extraUpFlags = ["--advertise-tags=tag:fireproof"];
      extraSetFlags = ["--operator=${config.fireproof.username}"];
    };

    # Work hosts also carry a work-tailnet profile (`tailnet toggle`); trusting the
    # interface there would open every port to work peers while that profile is active.
    networking.firewall.trustedInterfaces = lib.mkIf (!config.fireproof.work.enable) ["tailscale0"];

    # Boot lands on the personal (tagged) profile so autoconnect never fires the
    # auth key against the work profile. Only the active profile exposes its
    # tags, so "not tagged + exactly one other profile" → switch to it.
    systemd.services.tailscaled-autoconnect = {
      path = [pkgs.gawk];
      preStart = ''
        if tailscale status --json --peers=false 2>/dev/null \
          | jq -e '(.Self.Tags // []) | index("tag:fireproof")' >/dev/null; then
          exit 0
        fi
        other=$(tailscale switch --list 2>/dev/null | awk 'NR > 1 && $NF !~ /\*$/ {print $1}' || true)
        if [ "$(wc -w <<<"$other")" = 1 ]; then
          tailscale switch "$other"
        fi
      '';
    };
  };

  # macOS counterpart: the GUI client as a Homebrew cask (the standalone build,
  # not the sandboxed Mac App Store one). Ungated to match the always-on NixOS
  # half — Tailscale runs fleet-wide. No auth-key hook: log in once in the GUI.
  flake.modules.darwin.tailscale = _: {
    homebrew.casks = ["tailscale-app"];
  };
}
