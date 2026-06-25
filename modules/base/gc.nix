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
  # Inert under Determinate Nix (nix.enable = false), which runs its own GC.
  flake.modules.darwin.gc = {
    config,
    lib,
    ...
  }:
    lib.mkIf config.nix.enable {
      nix.gc = {
        automatic = true;
        options = "--delete-older-than 7d";
      };

      nix.optimise.automatic = true;
    };
}
