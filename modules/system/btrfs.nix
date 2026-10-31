{
  flake.modules.nixos.btrfs = {
    config,
    lib,
    ...
  }: let
    btrfsFileSystems = lib.filterAttrs (_: fs: fs.fsType == "btrfs") config.fileSystems;
    # Dedup by device so shared-device subvolumes (/, /nix, /home) scrub once, not per-subvolume.
    mountPerDevice =
      lib.listToAttrs
      (lib.mapAttrsToList (mountPoint: fs: lib.nameValuePair fs.device mountPoint) btrfsFileSystems);
    scrubMounts = lib.attrValues mountPerDevice;
  in {
    config = lib.mkIf (scrubMounts != []) (lib.mkMerge [
      {
        # Once every chunk is allocated, metadata can't grow and writes ENOSPC while df shows
        # free space. The kernel then repacks sparse data chunks itself, raising its threshold
        # as unallocated space shrinks; both knobs default off.
        systemd.tmpfiles.rules = [
          "w /sys/fs/btrfs/*/allocation/data/dynamic_reclaim - - - - 1"
          "w /sys/fs/btrfs/*/allocation/data/periodic_reclaim - - - - 1"
        ];
      }
      # Single-profile data only DETECTS bit-rot (journal-logged); DUP metadata self-heals.
      (lib.mkIf config.fireproof.hardware.physical {
        services.btrfs.autoScrub = {
          enable = true;
          interval = "monthly";
          fileSystems = scrubMounts;
        };
      })
    ]);
  };
}
