{
  flake.modules.nixos.gc = {lib, ...}: {
    # mkDefault: a generation costs ~60 MB of ESP, so 10 overflows a 512 MB ESP; those hosts cap it lower.
    boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;

    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };

    nix.optimise.automatic = true;

    # nixpkgs already idles nix-optimise, but not nix-gc.
    systemd.services.nix-gc.serviceConfig = {
      CPUSchedulingPolicy = "idle";
      IOSchedulingClass = "idle";
    };
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
