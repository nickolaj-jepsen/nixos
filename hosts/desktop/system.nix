{
  nixos = {
    programs.steam.enable = true;
    hardware.facter.reportPath = ./facter.json;

    users.users.nickolaj.extraGroups = ["dialout"]; # SO-101 arm's USB serial adapter (rustyarm)

    # builds phone-vm's aarch64 disk image
    boot.binfmt.emulatedSystems = ["aarch64-linux"];
  };
}
