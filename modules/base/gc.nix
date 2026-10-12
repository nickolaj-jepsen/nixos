{
  flake.modules.nixos.gc = {lib, ...}: {
    # mkDefault: a generation costs ~60 MB of ESP, so 10 overflows a 512 MB ESP; those hosts cap it lower.
    boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;

    # nh rather than nix.gc: `--delete-older-than` alone leaves a host that sat idle for a week with no
    # generation to roll back to. --no-gcroots keeps nix.gc's behaviour of leaving result/.direnv roots be.
    programs.nh = {
      enable = true;
      clean = {
        enable = true;
        dates = "weekly";
        extraArgs = "--keep 5 --keep-since 7d --no-gcroots";
      };
    };

    nix.optimise.automatic = true;

    # nixpkgs already idles nix-optimise, but not nh-clean.
    systemd.services.nh-clean.serviceConfig = {
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
