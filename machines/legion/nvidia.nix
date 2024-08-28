{ config, lib, pkgs, ... }:
{

  # Enable OpenGL
  hardware.opengl = {
    enable = true;
  };

  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = ["nvidia"];

  boot = {
    blacklistedKernelModules = lib.mkDefault [ "nouveau" ];
    kernelParams = [ "nvidia-drm.fbdev=1" ];
    kernelModules = [ "kvm-intel" "nvidia" "i915" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];
  };

  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    nvidiaSettings = true;
    modesetting.enable = true;
  };
}