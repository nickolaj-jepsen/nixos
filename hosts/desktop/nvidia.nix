_: {
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
}
