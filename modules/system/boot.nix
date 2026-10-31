{
  flake.modules.nixos.boot = {
    config,
    lib,
    ...
  }: {
    # WSL is booted by the Windows host and has no bootloader of its own.
    config = lib.mkIf (!config.fireproof.wsl.enable) {
      boot.loader.systemd-boot.enable = lib.mkDefault true;
      boot.loader.efi.canTouchEfiVariables = true;
      # The menu editor lets anyone at the keyboard add init=/bin/sh, a root shell on any
      # host whose disk unlocks without a password (TPM).
      boot.loader.systemd-boot.editor = false;
    };
  };
}
