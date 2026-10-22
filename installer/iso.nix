{
  pkgs,
  lib,
  inputs,
  ...
}: {
  # Upstream minimal installation ISO as the base.
  imports = [
    "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  users.motd = ''

    === NixOS installer (generic) ===

    This image installs no host of its own. Either drive `nixos-anywhere` from a
    machine with this flake checked out

      just deploy-remote <host> root@<this-machine>   # FORMATS this disk

    or install by hand: nmtui for WiFi, then the host's disko config followed by
    nixos-install. See docs/hosts.md.

  '';

  # `services.getty.helpLine` is what shows at the TTY login prompt (BEFORE the user
  # logs in and sees the MOTD). Upstream sets it to a passwd/wpa_supplicant blurb
  # that's wrong for this flow.
  services.getty.helpLine = lib.mkForce ''

    Generic installer. Log in as 'nixos' (no password): nmtui for WiFi, then
    either `nixos-install` by hand or `just deploy-remote` over ssh.

  '';

  # Password root SSH is what `just deploy-remote` (nixos-anywhere) logs into.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = lib.mkForce "yes";
      PasswordAuthentication = lib.mkForce true;
      KbdInteractiveAuthentication = lib.mkForce true;
    };
  };

  users.users.root = {
    initialHashedPassword = lib.mkForce null;
    initialPassword = lib.mkForce "nixos";
  };

  # Disable systemd-boot as we're using ISO bootloader
  boot.loader.systemd-boot.enable = lib.mkForce false;

  networking.networkmanager.enable = true;
  networking.wireless.enable = lib.mkForce false; # Conflicts with networkmanager

  # Installation tools
  environment.systemPackages = with pkgs; [
    # Disk tools
    gptfdisk
    parted
    cryptsetup
    btrfs-progs
    dosfstools
    ntfs3g

    # NixOS installation
    nixos-install-tools

    # Network tools
    wget
    curl
    git

    # Editors
    vim
    nano

    # System tools
    htop
    pciutils
    usbutils
    lsof

    # Hardware detection
    nixos-facter
  ];

  system.stateVersion = "25.11";
}
