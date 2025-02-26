{pkgs, config, ...}: {
  hardware.graphics = {
    enable = true;
  };
  services.xserver.videoDrivers = ["nvidia"];
  hardware.nvidia = {
    open = true;
    modesetting.enable = true;
    powerManagement.enable = true;
    nvidiaSettings = true;
  };

  # To fix https://forums.developer.nvidia.com/t/ubuntu-24-04-unable-to-change-power-state-from-d3cold-to-d0-device-inaccessible/304459
  boot.kernelPackages = pkgs.linuxPackages_6_12;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.latest;
}
