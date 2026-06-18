{
  flake.modules.nixos.btrfs-scrub = {
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
    # Single-profile data only DETECTS bit-rot (journal-logged); DUP metadata self-heals.
    config = lib.mkIf config.fireproof.hardware.physical (lib.mkIf (scrubMounts != []) {
      services.btrfs.autoScrub = {
        enable = true;
        interval = "monthly";
        fileSystems = scrubMounts;
      };
    });
  };
}
