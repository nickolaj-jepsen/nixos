{
  pkgs,
  lib,
  inputs,
  ...
}: {
  # Use the nixos installation ISO as base
  imports = [
    "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  # Disable systemd-boot as we're using ISO bootloader
  boot.loader.systemd-boot.enable = lib.mkForce false;

  # Enable SSH for remote installation
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = lib.mkForce "yes";
      PasswordAuthentication = lib.mkForce true;
      KbdInteractiveAuthentication = lib.mkForce true;
    };
  };

  # Set a root password for the live environment (override the ISO's empty password)
  users.users.root = {
    initialHashedPassword = lib.mkForce null;
    initialPassword = lib.mkForce "nixos";
  };

  # Networking
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
