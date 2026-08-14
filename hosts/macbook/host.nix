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

    # Local inference endpoint for personal data. The only host in the fleet with
    # enough memory for a 27B at a good quant — the desktop's 5070 Ti has 16 GB.
    # Holds ~18 GB locked, so this host is a lid-closed appliance, not a laptop.
    fireproof.llm.enable = true;
  };

  # nix-darwin system config (the macOS analog of a host's `nixos` bucket).
  darwin = {
    inputs,
    config,
    ...
  }: {
    # nix-homebrew owns the brew install + pinned taps; homebrew.* (below) the casks.
    nix-homebrew = {
      enable = true;
      # No x86_64-only brews/casks today (firefox + ghostty ship arm64); flip on
      # only if an Intel-only package needs the Rosetta /usr/local prefix.
      enableRosetta = false;
      user = config.fireproof.username;
      mutableTaps = false;
      taps = {
        "homebrew/homebrew-core" = inputs.homebrew-core;
        "homebrew/homebrew-cask" = inputs.homebrew-cask;
      };
    };

    homebrew = {
      enable = true;
      taps = builtins.attrNames config.nix-homebrew.taps;
      # Casks are co-located with their program leaves (each contributes its own
      # cask via flake.modules.darwin.<app>, gated on the app's fireproof toggle).
      # Prune undeclared brew packages (without zapping data); review before first switch.
      onActivation.cleanup = "uninstall";
    };

    # Don't idle-sleep or lock aggressively. Lid-close still sleeps (separate knob).
    power.sleep = {
      computer = "never"; # no system idle-sleep while the lid is open
      display = 30; # minutes of idle before the screen turns off
    };
    system.defaults = {
      screensaver = {
        askForPassword = true; # still require the password when it does lock
        askForPasswordDelay = 60; # ...but not until 60s after screen-off, so a nudge doesn't re-prompt
      };
      # When the screensaver (and thus the lock) kicks in, in seconds. 900 = 15 min.
      CustomUserPreferences."com.apple.screensaver".idleTime = 900;
    };
  };
}
