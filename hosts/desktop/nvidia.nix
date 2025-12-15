{config, ...}: {
  hardware = {
    graphics = {
      enable = true;
    };
    nvidia = {
      open = true;
      modesetting.enable = true;
      package = config.boot.kernelPackages.nvidiaPackages.beta;
    };
  };
  services.xserver.videoDrivers = ["nvidia"];

  fireproof.home-manager.programs.niri.settings = {
    environment = {
      "LIBVA_DRIVER_NAME" = "nvidia";
      "__GLX_VENDOR_LIBRARY_NAME" = "nvidia";
      "NVD_BACKEND" = "direct";
    };
  };
}
