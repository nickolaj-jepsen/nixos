{
  nixos = {
    facter.reportPath = ./facter.json;

    # cross-builds the Raspberry Pi kiosk SD image (~/dev/kiosk)
    boot.binfmt.emulatedSystems = ["aarch64-linux"];
  };
}
