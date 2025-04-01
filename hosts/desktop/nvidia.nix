_: {
  hardware = {
    graphics = {
      enable = true;
    };
    nvidia = {
      open = true;
      modesetting.enable = true;
    };
  };
  services.xserver.videoDrivers = ["nvidia"];

  fireproof.home-manager.wayland.windowManager.hyprland.settings = {
    env = [
      "LIBVA_DRIVER_NAME,nvidia"
      "__GLX_VENDOR_LIBRARY_NAME,nvidia"
      "NVD_BACKEND,direct"
    ];

    cursor.no_hardware_cursors = true;
  };
}
