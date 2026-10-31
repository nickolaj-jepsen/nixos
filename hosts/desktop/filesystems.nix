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
    boot.initrd.luks.devices.crypted = {
      device = "/dev/disk/by-partuuid/3f97b831-56f0-4fd0-a83e-2df7b5e285a5";
      allowDiscards = true;
      bypassWorkqueues = true;
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
    boot.tmp.cleanOnBoot = true;
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
      lib.mapAttrsToList (dir: mode: "v ${user.home}/${dir} ${mode} ${user.name} ${user.group} -") {
        ".cache" = "0755";
        "models" = "0755";
        ".local/share/Steam" = "0700";
        ".local/share/pnpm" = "0755";
        "vms" = "0755";
      }
      # VM disk images are rewritten in place; copy-on-write fragments them.
      ++ ["h ${user.home}/vms - - - - +C"];

    services.btrbk.instances.home = {
      onCalendar = "hourly";
      settings = {
        # btrbk deletes nothing unless retention is set.
        snapshot_preserve_min = "6h";
        snapshot_preserve = "24h 7d 4w";
        volume."/mnt/btrfs" = {
          snapshot_dir = "@snapshots";
          subvolume = "@home";
        };
      };
    };
  };
}
