{
  nixos = {
    programs.steam.enable = true;
    hardware.facter.reportPath = ./facter.json;
    # The NixOS manual is 5% of the eval's thunks (~1 s per rebuild).
    documentation.nixos.enable = false;

    users.users.nickolaj.extraGroups = ["dialout"]; # SO-101 arm's USB serial adapter (rustyarm)

    # builds phone-vm's aarch64 disk image
    boot.binfmt.emulatedSystems = ["aarch64-linux"];
  };
}
