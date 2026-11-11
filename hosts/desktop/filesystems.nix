# The NVMe it shares with Windows, partitioned by hand: a disko layout here would wipe Windows
# if ever run. hosts/_templates/disko/btrfs-luks.nix is the layout for a fresh disk.
{
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.users.users.${config.fireproof.username};
    btrfs = subvol: extra: {
      device = "/dev/mapper/crypted";
      fsType = "btrfs";
      options = ["subvol=${subvol}" "compress=zstd:1" "noatime"] ++ extra;
    };
  in {
    # The 970 EVO Plus takes ~8 ms to wake from PS4 (entered after 100 ms idle), a stall on every
    # cold read; 5000 µs still allows PS3 (1.2 ms exit).
    boot.kernelParams = ["nvme_core.default_ps_max_latency_us=5000"];

    boot.initrd.luks.devices.crypted = {
      device = "/dev/disk/by-partuuid/3f97b831-56f0-4fd0-a83e-2df7b5e285a5";
      allowDiscards = true;
      bypassWorkqueues = true;
      # No YubiKey slot: the typed passphrase is what autologin reuses to unlock the keyring.
    };

    fileSystems = {
      "/" = btrfs "@" [];
      "/nix" = btrfs "@nix" [];
      "/home" = btrfs "@home" [];
      "/tmp" = btrfs "@tmp" [];
      "/var/lib/docker" = btrfs "@docker" [];
      # btrbk works on the top level, where @home and @snapshots sit side by side.
      "/mnt/btrfs" = btrfs "/" ["noauto" "x-systemd.automount" "x-systemd.idle-timeout=10min"];
      # Shared with Windows' boot manager.
      "/boot" = {
        device = "/dev/disk/by-partuuid/811a3c22-daaf-47d8-9b19-94adf986df12";
        fsType = "vfat";
        options = ["umask=0077"];
      };
    };

    # Agents dump scratch into /tmp; the limit keeps them from filling /. The limit lives in the
    # filesystem (squota, enabled at mkfs); this keeps it at the configured value.
    #
    # cleanOnBoot deletes inside systemd-tmpfiles-setup, which holds sysinit.target (and so the
    # greeter) for as long as it takes: 17 s and 53 s were seen. Renaming is instant, so last
    # boot's contents are set aside before tmpfiles runs and deleted once the system is up.
    systemd.services.tmp-set-aside = {
      description = "Set last boot's /tmp aside";
      wantedBy = ["sysinit.target"];
      before = ["systemd-tmpfiles-setup.service"];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = "/tmp";
      };
      path = [pkgs.coreutils pkgs.findutils];
      serviceConfig.Type = "oneshot";
      script = ''
        # Only at boot: a switch starts this unit too, and /tmp is then in use.
        systemctl is-active --quiet systemd-tmpfiles-setup.service && exit 0
        mkdir -p /tmp/.reap
        find /tmp -mindepth 1 -maxdepth 1 ! -name .reap \
          -exec mv -t "$(mktemp -d -p /tmp/.reap)" {} +
      '';
    };
    systemd.services.tmp-reap = {
      description = "Delete last boot's /tmp";
      wantedBy = ["multi-user.target"];
      after = ["tmp-set-aside.service"];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${pkgs.coreutils}/bin/rm -rf /tmp/.reap";
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };
    systemd.services.tmp-quota = {
      description = "Limit /tmp to 40G";
      wantedBy = ["multi-user.target"];
      unitConfig.RequiresMountsFor = "/tmp";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.btrfs-progs}/bin/btrfs qgroup limit 40G /tmp";
      };
    };

    # Nested subvolumes stay out of /home's snapshots: rebuildable, or churn that snapshots would pin.
    systemd.tmpfiles.rules =
      ["d ${user.home}/.local/state/agents 0700 ${user.name} ${user.group} -"]
      ++ lib.mapAttrsToList (dir: mode: "v ${user.home}/${dir} ${mode} ${user.name} ${user.group} -") {
        ".cache" = "0755";
        "models" = "0755";
        ".local/share/Steam" = "0700";
        ".local/share/pnpm" = "0755";
        # Agent scratch is aged out by tmpfiles; a snapshot would pin what it frees.
        ".local/state/agents/tmp" = "0700";
        "vms" = "0755";
      }
      # VM disk images are rewritten in place; copy-on-write fragments them.
      ++ ["h ${user.home}/vms - - - - +C"];

    services.btrbk.instances.home = {
      onCalendar = "hourly";
      settings = {
        # sudo is wheel-only (security leaf), so the btrbk user's sudo backend can't run; local
        # snapshots need no privilege separation.
        backend = "btrfs-progs";
        # btrbk deletes nothing unless retention is set.
        snapshot_preserve_min = "6h";
        snapshot_preserve = "24h 7d 4w";
        volume."/mnt/btrfs" = {
          snapshot_dir = "@snapshots";
          subvolume = "@home";
        };
      };
    };
    systemd.services.btrbk-home.serviceConfig.User = lib.mkForce "root";
  };
}
