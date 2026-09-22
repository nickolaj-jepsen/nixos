{
  # 512 MB ESP at ~60 MB per generation: the default 10 overflows it.
  nixos.boot.loader.systemd-boot.configurationLimit = 5;
}
