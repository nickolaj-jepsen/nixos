{
  nixos = {pkgs, ...}: {
    # VA-API for the UHD 630, which renders everything not PRIME-offloaded; Mesa has no Intel backend.
    hardware.graphics.extraPackages = [pkgs.intel-media-driver];

    networking.networkmanager.enable = true;
    users.users.nickolaj.extraGroups = ["networkmanager"];

    services.xserver.videoDrivers = ["nvidia"];

    hardware.nvidia = {
      open = true;
      powerManagement.enable = true;
      powerManagement.finegrained = true;
      prime = {
        offload = {
          enable = true;
          enableOffloadCmd = true;
        };
        intelBusId = "PCI:0:2:0";
        nvidiaBusId = "PCI:1:0:0";
      };
    };
  };
}
