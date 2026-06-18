{
  flake.modules.nixos.btrfs-scrub = {
    config,
    lib,
    ...
  }: let
    btrfsFileSystems = lib.filterAttrs (_: fs: fs.fsType == "btrfs") config.fileSystems;
    # One mount point per unique backing device, so a filesystem is scrubbed
    # once rather than once per subvolume (/, /nix, /home share one device).
    mountPerDevice =
      lib.listToAttrs
      (lib.mapAttrsToList (mountPoint: fs: lib.nameValuePair fs.device mountPoint) btrfsFileSystems);
    scrubMounts = lib.attrValues mountPerDevice;
  in {
    # Monthly read-only checksum verification of every btrfs filesystem.
    # Single-profile data means scrub DETECTS bit-rot (logged to the journal),
    # while DUP metadata self-heals. Auto-detected so each host scrubs only the
    # btrfs it actually has (homelab's ext4/mergerfs data is skipped).
    config = lib.mkIf config.fireproof.hardware.physical (lib.mkIf (scrubMounts != []) {
      services.btrfs.autoScrub = {
        enable = true;
        interval = "monthly";
        fileSystems = scrubMounts;
      };
    });
  };
}
