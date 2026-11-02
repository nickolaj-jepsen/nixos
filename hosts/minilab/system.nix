{
  nixos = {
    lib,
    pkgs,
    ...
  }: {
    hardware.facter.reportPath = ./facter.json;

    # VA-API for the UHD 600; Mesa has no Intel backend, so video would decode on the Celeron.
    hardware.graphics.extraPackages = [pkgs.intel-media-driver];

    # eMMC only: smartmontools can't read it, so smartd exits 17 and fails every switch.
    services.smartd.enable = lib.mkForce false;
  };
}
