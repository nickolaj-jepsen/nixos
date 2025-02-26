{pkgsUnstable, ...}: {
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

  # Avoid nvidia driver from crashing the system
  boot.kernelParams = ["pcie_aspm=off"];

  # To fix https://forums.developer.nvidia.com/t/ubuntu-24-04-unable-to-change-power-state-from-d3cold-to-d0-device-inaccessible/304459
  boot.kernelPackages = pkgsUnstable.linuxPackages_latest;
}
