{
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    nvidia = config.boot.kernelPackages.nvidiaPackages;
    # 595.71.05 (26.05's production) doesn't build on 7.3; this is unstable's production
    # driver, and it switches itself off once 26.05 catches up.
    driver =
      if lib.versionOlder nvidia.production.version "595.112.07"
      then
        nvidia.mkDriver {
          version = "595.112.07";
          sha256_64bit = "sha256-Gjjs1Tii2mIypzMBhAY69Z6fyUbJCMylVb0HkJhIufA=";
          sha256_aarch64 = "sha256-7qQuOKX9xS/wpKa+bEOqsS2euJjJu182vl+6UU6bxR0=";
          openSha256 = "sha256-nQnXGCcvo4i7eGaVft3Xc9dRUPPH0v9Zi87cfI4i/Ys=";
          settingsSha256 = "sha256-2bWSou/9J3EojhSRXBol/+yGGu2XZ6EuCptb5qXHM14=";
          persistencedSha256 = "sha256-cGMEUXN7WPu822zZDLTSu6Owj8VXG4PNmhe9oKqMMKI=";
        }
      else nvidia.${config.hardware.nvidia.branch};
  in {
    # Latest rather than LTS: nested Hyper-V in the windows-vm guest needs the newest KVM.
    boot.kernelPackages = pkgs.linuxPackages_latest;

    # Limine reads and hashes the whole initrd under Secure Boot, so its size is loader time.
    # The RTX 5070 Ti (Blackwell) loads gsp_ga10x.bin; gsp_tu10x.bin is Turing's, ~15 MB packed.
    hardware.nvidia.package =
      driver
      // {
        firmware = pkgs.runCommand "nvidia-firmware-${driver.version}-ga10x" {} ''
          cp -r ${driver.firmware} $out
          chmod -R u+w $out
          rm $out/lib/firmware/nvidia/${driver.version}/gsp_tu10x.bin
        '';
      };

    # Only the i9-9900K's microcode (signature 0x906ec) instead of every Intel CPU's, which is
    # 15 MB of uncompressed initrd. A different CPU boots on its BIOS microcode until this changes.
    hardware.cpu.intel.microcodePackage = pkgs.runCommand "microcode-intel-906ec" {} ''
      mkdir $out
      ${lib.getExe pkgs.iucode-tool} -tr -s 0x906ec --write-earlyfw=$out/intel-ucode.img \
        ${pkgs.microcode-intel}/intel-ucode.img
    '';

    # On trial against systemd-boot + lanzaboote; the go/no-go criteria are in the
    # nvme-migration plan in this repo's agent notes.
    boot.loader.systemd-boot.enable = false;
    boot.loader.limine = {
      enable = true;
      # 12.9 checks hashes before decompressing and hides the shell hotkey under Secure Boot.
      package = pkgs.unstable.limine;
      # Kernels and initrds are shared between generations on the 2 GiB ESP; an initrd with
      # NVIDIA's early KMS is ~150 MB.
      maxGenerations = 5;
      # Keys in /var/lib/sbctl, enrolled with Microsoft's (the GPU's option ROM and Windows).
      secureBoot.enable = true;
      # The ESP is shared with Windows, so its boot manager is a plain chainload; the
      # firmware verifies it under Secure Boot.
      extraEntries = ''
        /Windows 11
          protocol: efi
          path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
      '';
    };
  };
}
