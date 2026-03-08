{
  pkgs,
  lib,
  ...
}: {
  boot = {
    # Use grub as bootloader as it works better with mdadm
    loader.grub.enable = true;
    loader.systemd-boot.enable = lib.mkForce false;

    # Ensure NVIDIA kernel modules are loaded at boot for headless GPU transcoding
    kernelModules = ["nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm"];

    # HACK: silence mdadm warning on missing MAILADDR or PROGRAM setting
    swraid.mdadmConf = ''
      PROGRAM ${pkgs.coreutils}/bin/true
    '';
  };

  # Enable OpenGL and NVIDIA VAAPI for hardware-accelerated transcoding
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      nvidia-vaapi-driver
    ];
  };

  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = ["nvidia"];

  hardware.nvidia = {
    open = false;
    modesetting.enable = true;
    nvidiaPersistenced = true;
  };
}
