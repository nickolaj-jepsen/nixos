# First deploy needs an on-Mac bootstrap (host key + rekey); see the justfile darwin-switch recipe.
{
  class = "darwin";

  shared = {
    fireproof.hostname = "macbook";

    # One toggle, like a Linux desktop: pulls in the full GUI roster (firefox,
    # vscode, ghostty, obsidian, slack, sublime-merge, spotify, chrome, zed,
    # pycharm) plus the Mac-only casks (karabiner, bitwarden, linear,
    # claude-desktop, handy, whatcable). The Linux-only DE (niri, dms, gtk, …) is
    # isLinux-gated out. Tailscale rides the always-on tailscale leaf's darwin
    # half. InputLeap is omitted — no Homebrew cask exists.
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
  homeManager.home.stateVersion = "24.11";
}
