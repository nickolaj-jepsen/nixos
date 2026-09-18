{
  nixos.boot.loader.systemd-boot = {
    windows."11".efiDeviceHandle = "HD1d";
    # 512 MB ESP: a 4th kernel version overflows the FAT mid-write; 3 peaks at ~84%.
    configurationLimit = 3;
  };
}
