{
  flake.modules.nixos.gc = {lib, ...}: {
    # mkDefault: a generation costs ~60 MB of ESP, so 10 overflows a 512 MB ESP; those hosts cap it lower.
    boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;

    # `nh clean all` expires every profile, users' home-manager ones included, drops
    # `result` links older than the window (never `.direnv`), then collects.
    programs.nh = {
      enable = true;
      clean = {
        enable = true;
        dates = "weekly";
        extraArgs = "--keep-since 7d";
      };
    };

    nix.optimise.automatic = true;

    # nixpkgs already idles nix-optimise, but not nh-clean.
    systemd.services.nh-clean.serviceConfig = {
      CPUSchedulingPolicy = "idle";
      IOSchedulingClass = "idle";
    };
  };

  flake.modules.homeManager.gc = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkMerge [
      # A standalone host has no NixOS nh-clean, so it cleans its own profiles and roots.
      (lib.mkIf (!config.submoduleSupport.enable && pkgs.stdenv.isLinux) {
        programs.nh = {
          enable = true;
          clean = {
            enable = true;
            dates = "weekly";
            extraArgs = "--keep-since 7d";
          };
        };
      })
      # Nothing cleans build dirs or tool caches on a timer: `disk-report` lists
      # what is big, with the command that clears each, and kondo picks build dirs.
      (lib.mkIf config.fireproof.dev.enable {
        home.packages = [pkgs.kondo] ++ lib.optional pkgs.stdenv.isLinux pkgs.disk-report;
      })
    ];
  };

  # darwin: Determinate Nix collects garbage itself (nix.nix), but generations stay
  # GC roots until expired, so expire them here and leave the collecting to it.
  # Embedded HM keeps no profile of its own; its generations ride in the system's.
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
}
