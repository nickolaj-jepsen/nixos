{pkgs, ...}: {
  # Data disks
  environment.systemPackages = with pkgs; [
    mergerfs
  ];
  fileSystems."/mnt/data-disk/1" = {
    device = "/dev/disk/by-id/ata-WDC_WD120EFBX-68B0EN0_5PKURKPF-part1";
    fsType = "ext4";
  };
  fileSystems."/mnt/data-disk/2" = {
    device = "/dev/disk/by-id/ata-WDC_WD120EFBX-68B0EN0_5PKVMK7F-part1";
    fsType = "ext4";
  };
  fileSystems."/mnt/longhorn" = {
    device = "/dev/disk/by-id/ata-TOSHIBA_HDWE160_26N7K5N0F56D-part1";
    fsType = "ext4";
  };
  fileSystems."/mnt/data" = {
    fsType = "fuse.mergerfs";
    device = "/mnt/data-disk/*";
    options = ["cache.files=partial" "dropcacheonclose=true" "category.create=mfs"];
  };

  # System disks
  disko.devices = {
    disk = {
      system1 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WDS500G2B0A-00SM50_1827AD804249";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02"; # for grub MBR
            };
            ESP = {
              size = "500M";
              type = "EF00";
              content = {
                type = "mdraid";
                name = "boot";
              };
            };
            mdadm = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "system";
              };
            };
          };
        };
      };
      system2 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WDS500G2B0A-00SM50_1908BB805114";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02"; # for grub MBR
            };
            ESP = {
              size = "500M";
              type = "EF00";
              content = {
                type = "mdraid";
                name = "boot";
              };
            };
            mdadm = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "system";
              };
            };
          };
        };
      };
    };
    mdadm = {
      boot = {
        type = "mdadm";
        level = 1;
        metadata = "1.0";
        content = {
          type = "filesystem";
          format = "vfat";
          mountpoint = "/boot";
          mountOptions = ["umask=0077"];
        };
      };
      system = {
        type = "mdadm";
        level = 1;
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
}
