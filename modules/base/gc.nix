{
  flake.modules.nixos.gc = _: {
    boot.loader.systemd-boot.configurationLimit = 10;

    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };

    nix.optimise.automatic = true;
  };

  # nix-darwin: same GC + optimise (no boot.loader; launchd default interval).
  flake.modules.darwin.gc = _: {
    nix.gc = {
      automatic = true;
      options = "--delete-older-than 7d";
    };

    nix.optimise.automatic = true;
  };
}
