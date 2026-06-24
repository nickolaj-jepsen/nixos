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
      enableRosetta = true;
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
      casks = ["firefox"];
      # Prune undeclared brew packages (without zapping data); review before first switch.
      onActivation.cleanup = "uninstall";
    };
  };
}
