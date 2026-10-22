# First deploy needs an on-Mac bootstrap (host key + rekey); see "First switch on a fresh Mac" in docs/hosts.md.
{
  class = "darwin";

  shared = {
    fireproof.hostname = "macbook";

    # One toggle, like a Linux desktop: pulls in the full GUI roster plus the
    # Mac-only casks; the Linux-only DE is isLinux-gated out. Tailscale rides the
    # always-on tailscale leaf's darwin half. InputLeap is omitted — no Homebrew cask exists.
    fireproof.desktop.enable = true;
    fireproof.dev.enable = true;
    fireproof.work.enable = true;
    fireproof.claude-code.work.enable = true;

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
