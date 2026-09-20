{inputs, ...}: {
  flake.modules.darwin.homebrew = {config, ...}: {
    imports = [inputs.nix-homebrew.darwinModules.nix-homebrew];

    # nix-homebrew owns the brew install + pinned taps; homebrew.* (below) the casks.
    nix-homebrew = {
      enable = true;
      # Only for an Intel-only brew/cask (Rosetta /usr/local prefix); none today.
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
      # Casks come from the program leaves' flake.modules.darwin.<app> halves.
      # Prune undeclared brew packages (without zapping data); review before first switch.
      onActivation.cleanup = "uninstall";
    };
  };
}
