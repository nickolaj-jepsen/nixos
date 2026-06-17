{
  flake.aspectTags.wsl = ["wsl"];
  flake.modules.nixos.wsl = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.wsl.enable {
      wsl = {
        enable = true;
        defaultUser = config.fireproof.username;
        startMenuLaunchers = true;
        interop.includePath = false;
        usbip.enable = true;
      };

      # WSL doesn't use a bootloader - disable systemd-boot
      boot.loader.systemd-boot.enable = false;
      boot.loader.efi.canTouchEfiVariables = false;
    };
  };
}
