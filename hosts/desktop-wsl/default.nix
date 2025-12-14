{
  config = rec {
    fireproof = {
      hostname = "desktop-wsl";
      username = "nickolaj";
      work.enable = true;
      dev.enable = true;
    };

    wsl.enable = true;
    wsl.defaultUser = fireproof.username;

    services.keyd.enable = false;

    system.stateVersion = "25.11";

    # WSL doesn't use a bootloader - disable systemd-boot
    boot.loader.systemd-boot.enable = false;
    boot.loader.efi.canTouchEfiVariables = false;
  };

  imports = [
    ./ssh.nix
  ];
}
