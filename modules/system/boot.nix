{inputs, ...}: {
  flake.modules.nixos.boot = {
    config,
    lib,
    pkgs,
    ...
  }: let
    limine = config.boot.loader.limine;
  in {
    # 26.05's limine module has no extraInstallCommands, which the signing check below needs.
    # Inert on hosts that don't enable Limine.
    disabledModules = ["system/boot/loader/limine/limine.nix"];
    imports = ["${inputs.nixpkgs-unstable}/nixos/modules/system/boot/loader/limine/limine.nix"];

    # WSL is booted by the Windows host and has no bootloader of its own.
    config = lib.mkIf (!config.fireproof.wsl.enable) {
      boot.loader.systemd-boot.enable = lib.mkDefault true;
      boot.loader.efi.canTouchEfiVariables = true;
      # The menu editor lets anyone at the keyboard add init=/bin/sh, a root shell on any
      # host whose disk unlocks without a password (TPM).
      boot.loader.systemd-boot.editor = false;

      # The installer ignores a failed `sbctl sign`, so a rebuild would succeed and the next boot
      # hit a Secure Boot violation; fail the rebuild instead.
      boot.loader.limine.extraInstallCommands = lib.mkIf limine.secureBoot.enable ''
        ${pkgs.sbsigntool}/bin/sbverify --cert /var/lib/sbctl/keys/db/db.pem \
          ${config.boot.loader.efi.efiSysMountPoint}/efi/${
          if limine.efiInstallAsRemovable
          then "boot"
          else "limine"
        }/BOOTX64.EFI
      '';
    };
  };
}
