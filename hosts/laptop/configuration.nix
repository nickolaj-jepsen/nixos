{pkgs, ...}: {
  fireproof.desktop.enable = true;
  fireproof.work.enable = true;
  fireproof.dev.enable = true;
  # Enable OpenGL
  hardware.graphics = {
    enable = true;
  };

  networking.networkmanager.enable = true;
  users.users.nickolaj.extraGroups = ["networkmanager"];
  programs.nm-applet.enable = true;

  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = ["nvidia"];

  environment.systemPackages = [
    pkgs.mesa-demos
  ];

  hardware.nvidia = {
    open = true;
    modesetting.enable = true;
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    nvidiaSettings = true;
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };
}
