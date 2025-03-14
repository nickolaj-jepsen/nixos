{
  pkgs,
  config,
  ...
}: {
  hardware = {
    graphics = {
      enable = true;
    };
    nvidia = {
      open = true;
      modesetting.enable = true;
      powerManagement.enable = true;
      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.latest;
    };
  };
  services.xserver.videoDrivers = ["nvidia"];

  # To fix https://forums.developer.nvidia.com/t/ubuntu-24-04-unable-to-change-power-state-from-d3cold-to-d0-device-inaccessible/304459
  boot.kernelPackages = pkgs.linuxPackages_6_12;

  fireproof.home-manager.wayland.windowManager.hyprland.settings = {
    env = [
      "LIBVA_DRIVER_NAME,nvidia"
      "__GLX_VENDOR_LIBRARY_NAME,nvidia"
      "NVD_BACKEND,direct"
    ];

    cursor.no_hardware_cursors = true;
  };
}
