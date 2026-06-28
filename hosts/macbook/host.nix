# First deploy needs an on-Mac bootstrap (host key + rekey); see the justfile darwin-switch recipe.
{
  class = "darwin";

  shared = {
    fireproof.hostname = "macbook";

    fireproof.dev.enable = true;
    fireproof.work.enable = true;
    fireproof.claude-code.work.enable = true;

    # clickhouse: heavy/flaky on darwin and unused locally.
    fireproof.dev.clickhouse.enable = false;

    fireproof.firefox.enable = true;
    fireproof.vscode.enable = true;
    fireproof.ghostty.enable = true;
    fireproof.karabiner.enable = true;

    # Hand-installed GUI apps now declared as casks (Tailscale rides the always-on
    # tailscale leaf's darwin half). InputLeap is omitted — no Homebrew cask exists.
    fireproof.bitwarden.enable = true;
    fireproof.obsidian.enable = true;
    fireproof.claude-desktop.enable = true;
    fireproof.slack.enable = true;
    fireproof.linear.enable = true;
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
  };
}
