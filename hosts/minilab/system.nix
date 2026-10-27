{
  nixos = {pkgs, ...}: {
    hardware.facter.reportPath = ./facter.json;

    # CI probe: changes minilab's toplevel and nothing else.
    environment.etc."ci-probe".text = "probe";

    # VA-API for the UHD 600; Mesa has no Intel backend, so video would decode on the Celeron.
    hardware.graphics.extraPackages = [pkgs.intel-media-driver];
  };
}
