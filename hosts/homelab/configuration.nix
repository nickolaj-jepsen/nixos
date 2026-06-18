{
  nixos = {
    config,
    pkgs,
    lib,
    ...
  }: {
    boot = {
      # Use grub as bootloader as it works better with mdadm
      loader.grub.enable = true;
      loader.systemd-boot.enable = lib.mkForce false;

      # Keep the AHCI driver in the initrd so the system still boots after
      # switching the BIOS SATA mode from IDE (ata_piix) to AHCI. Device paths
      # are by-id, so they stay stable across the switch.
      initrd.availableKernelModules = ["ahci"];

      # Ensure NVIDIA kernel modules are loaded at boot for headless GPU transcoding
      kernelModules = ["nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm"];

      # HACK: silence mdadm warning on missing MAILADDR or PROGRAM setting
      swraid.mdadmConf = ''
        PROGRAM ${pkgs.coreutils}/bin/true
      '';
    };

    # Monitor SMART health on the SSDs and spinning disks; log failures to the
    # journal so a failing drive surfaces before it dies.
    services.smartd.enable = true;

    # Enable OpenGL and NVIDIA VAAPI for hardware-accelerated transcoding
    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs; [
        nvidia-vaapi-driver
      ];
    };

    services.xserver.videoDrivers = ["nvidia"];

    hardware.nvidia = {
      open = false;
      modesetting.enable = true;
      nvidiaPersistenced = true;
      # GTX 970 (Maxwell) is only supported by the 580.xx legacy branch;
      # the default current driver drops Maxwell and ignores the GPU.
      package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
    };
  };
}
