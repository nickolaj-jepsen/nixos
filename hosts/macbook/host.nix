# First deploy: `sudo ssh-keygen -A`; replace the dummy pub/age pair with the
# real /etc/ssh/ssh_host_ed25519_key{,.pub} (encrypt as in scripts/new-host.sh);
# `just secret-rekey`. Until darwin-rebuild is on PATH:
# `nix run nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch --flake .#macbook`.
# Review homebrew.onActivation.cleanup first. Enable Remote Login with
# `sudo systemsetup -setremotelogin on`; Nix only manages sshd's config.
{
  class = "darwin";

  shared = {
    fireproof.hostname = "macbook";
    fireproof.trusted = true;

    # One toggle, like a Linux desktop: pulls in the full GUI roster plus the
    # Mac-only casks; the Linux-only DE is isLinux-gated out. Tailscale rides the
    # always-on tailscale leaf's darwin half. InputLeap is omitted — no Homebrew cask exists.
    fireproof.desktop.enable = true;
    fireproof.dev.enable = true;
    fireproof.dev.agent-hub.viewers = ["work"];
    fireproof.work.enable = true;
    fireproof.claude-code.work.enable = true;
    fireproof.dev.pi.work.enable = true;

    # chromium: Linux-only here; the Mac browser-extra is google-chrome's cask.
    fireproof.desktop.chromium.enable = false;

    # clickhouse: heavy/flaky on darwin and unused locally.
    fireproof.dev.clickhouse.enable = false;
  };

  darwin.system.stateVersion = 7;
  homeManager = {
    home.stateVersion = "24.11";
    # Real app copies Spotlight indexes (vscode); the default only from stateVersion 25.11.
    targets.darwin.copyApps.enable = true;
    targets.darwin.linkApps.enable = false;
  };
}
