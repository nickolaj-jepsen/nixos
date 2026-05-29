_: {
  hardware = {
    graphics = {
      enable = true;
    };
    nvidia = {
      open = true;
      modesetting.enable = true;
      powerManagement.enable = true;
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
