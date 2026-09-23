{
  # 512 MB ESP with ~135 MB initrds (NVIDIA GSP firmware): old entries are only
  # pruned after the new one is written, so 3 kept + 1 new overflows.
  nixos.boot.loader.systemd-boot.configurationLimit = 2;
}
