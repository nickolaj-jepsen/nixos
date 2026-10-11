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

  # darwin: Determinate Nix collects garbage itself (nix.nix), but generations stay
  # GC roots until expired, so expire them here and leave the collecting to it.
  flake.modules.darwin.gc = {
    launchd.daemons.expire-system-generations = {
      # Determinate's nix-env, matching its daemon; launchd's PATH has no nix.
      script = "/nix/var/nix/profiles/default/bin/nix-env -p /nix/var/nix/profiles/system --delete-generations 7d";
      serviceConfig.StartCalendarInterval = [
        {
          Weekday = 7;
          Hour = 3;
          Minute = 15;
        }
      ];
    };
  };

  flake.modules.homeManager.gc = {
    lib,
    pkgs,
    ...
  }: {
    # HM picks its profile dir at activation, so let its own expirer find it.
    services.home-manager.autoExpire = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;
      timestamp = "-7 days";
      frequency = "weekly";
    };
  };
}
