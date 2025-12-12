{
  pkgs,
  lib,
  ...
}: {
  fireproof.dev.enable = true;

  boot = {
    # Use grub as bootloader as it works better with mdadm
    loader.grub.enable = true;
    loader.systemd-boot.enable = lib.mkForce false;

    # HACK: silence mdadm warning on missing MAILADDR or PROGRAM setting
    swraid.mdadmConf = ''
      PROGRAM ${pkgs.coreutils}/bin/true
    '';
  };

  # Enable OpenGL
  hardware.graphics = {
    enable = true;
  };

  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = ["nvidia"];

  hardware.nvidia = {
    open = true;
    modesetting.enable = true;
  };
}
