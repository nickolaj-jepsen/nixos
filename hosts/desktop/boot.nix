{
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    nvidia = config.boot.kernelPackages.nvidiaPackages;
  in {
    # Latest rather than LTS: nested Hyper-V in the windows-vm guest needs the newest KVM.
    boot.kernelPackages = pkgs.linuxPackages_latest;

    # 595.71.05 (26.05's production) doesn't build on 7.3; this is unstable's production
    # driver, and it switches itself off once 26.05 catches up.
    hardware.nvidia.package = lib.mkIf (lib.versionOlder nvidia.production.version "595.112.07") (nvidia.mkDriver {
      version = "595.112.07";
      sha256_64bit = "sha256-Gjjs1Tii2mIypzMBhAY69Z6fyUbJCMylVb0HkJhIufA=";
      sha256_aarch64 = "sha256-7qQuOKX9xS/wpKa+bEOqsS2euJjJu182vl+6UU6bxR0=";
      openSha256 = "sha256-nQnXGCcvo4i7eGaVft3Xc9dRUPPH0v9Zi87cfI4i/Ys=";
      settingsSha256 = "sha256-2bWSou/9J3EojhSRXBol/+yGGu2XZ6EuCptb5qXHM14=";
      persistencedSha256 = "sha256-cGMEUXN7WPu822zZDLTSu6Owj8VXG4PNmhe9oKqMMKI=";
    });

    boot.loader.systemd-boot = {
      # Windows' ESP is on the NVMe, which systemd-boot can't chainload across. The
      # stock `windows.<n>.efiDeviceHandle` hardcodes a shell handle (HD1d) that shifts
      # with firmware disk enumeration; instead a dedicated shell copy runs the
      # startup.nsh beside it, which connects every disk and searches for bootmgfw.efi.
      extraFiles = {
        "efi/windows/shell.efi" = "${pkgs.edk2-uefi-shell}/shell.efi";
        "efi/windows/startup.nsh" = pkgs.writeText "startup.nsh" ''
          @echo -off
          connect -r
          map -r
          for %a run (0 15)
            if exist fs%a:\EFI\Microsoft\Boot\bootmgfw.efi then
              fs%a:\EFI\Microsoft\Boot\bootmgfw.efi
            endif
          endfor
          echo "bootmgfw.efi not found on any filesystem; 'map' lists them, 'exit' returns to systemd-boot"
        '';
      };
      extraEntries."windows_11.conf" = ''
        title Windows 11
        efi /efi/windows/shell.efi
        options -nointerrupt -nomap -noversion
        sort-key o_windows_11
      '';
      # 512 MB ESP: a 4th kernel version overflows the FAT mid-write; 3 peaks at ~84%.
      configurationLimit = 3;
    };
  };
}
