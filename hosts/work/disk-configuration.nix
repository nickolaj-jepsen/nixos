{
  nixos = {
    disko.devices = {
      disk = {
        main = {
          device = "/dev/disk/by-id/nvme-SAMSUNG_MZVL81T0HELB-00BH1_S79UNX0XC63332";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              boot = {
                name = "boot";
                size = "1M";
                type = "EF02";
              };

              ESP = {
                size = "512M";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = ["umask=0077"];
                };
              };
              luks = {
                size = "100%";
                content = {
                  type = "luks";
                  name = "crypted";
                  # Copied by deploy script, otherwise it will prompt for password
                  passwordFile = "/luks-password";
                  settings = {
                    allowDiscards = true;
                    bypassWorkqueues = true;
                  };
                  content = {
                    type = "btrfs";
                    extraArgs = ["-f"];
                    subvolumes = {
                      "@" = {
                        mountpoint = "/";
                        mountOptions = ["compress=zstd" "noatime"];
                      };
                      "@nix" = {
                        mountpoint = "/nix";
                        mountOptions = ["compress=zstd" "noatime"];
                      };
                      "@home" = {
                        mountpoint = "/home";
                        mountOptions = ["compress=zstd" "noatime"];
                      };
                    };
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
