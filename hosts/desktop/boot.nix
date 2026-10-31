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

    # On trial against systemd-boot + lanzaboote; the go/no-go criteria are in
    # ~/.local/share/agents/nvme-migration/plan.md.
    boot.loader.systemd-boot.enable = false;
    boot.loader.limine = {
      enable = true;
      # 12.9 checks hashes before decompressing and hides the shell hotkey under Secure Boot.
      package = pkgs.unstable.limine;
      # Kernels and initrds are shared between generations on the 2 GiB ESP.
      maxGenerations = 10;
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

    # The TPM PIN and passphrase prompts. No NVIDIA early KMS: it adds ~90 MB to every initrd
    # (see the nvidia leaf), so the splash runs on the firmware framebuffer.
    boot.plymouth.enable = true;
    boot.kernelParams = ["quiet"];
  };
}
