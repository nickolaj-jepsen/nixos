{
  # 512 MB ESP: the default 10 generations overflow it.
  nixos.boot.loader.systemd-boot.configurationLimit = 3;
}
