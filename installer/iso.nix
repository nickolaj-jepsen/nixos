{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  targetHost = config.installer.targetHost;
  hostBaked = targetHost != "";

  motd =
    if hostBaked
    then ''

      === NixOS bootstrap ISO — target host: ${targetHost} ===

      Next steps:
        1. nmtui              # connect WiFi (skip if wired)
        2. bootstrap-install  # format disk + install NixOS (auto-elevates)

      After install: reboot, then `cd ~/nixos && git status` to review
      any live-generated configs (facter.json, disk-configuration.nix).
      Then wipe or reflash this stick: it holds ${targetHost}'s private host key.

    ''
    else ''

      === NixOS bootstrap ISO (generic) ===

      This ISO is not built for a specific host — `bootstrap-install` is
      not installed. To produce a host-specific install ISO, run on a
      machine with the YubiKey present:

        just bootstrap-iso <hostname>
        just bootstrap-flash <hostname> /dev/sdX

    '';

  # `services.getty.helpLine` is what shows at the TTY login prompt
  # (BEFORE the user logs in and sees the MOTD). Upstream sets it to a
  # passwd/wpa_supplicant blurb that's wrong for our flow.
  helpLine =
    if hostBaked
    then ''

      Bootstrap ISO for host: ${targetHost}
      Log in as 'nixos' (no password), then:
        1. nmtui                  - connect WiFi if wired isn't up
        2. bootstrap-install      - format disk + install NixOS

    ''
    else ''

      Generic bootstrap ISO. Build a host-specific ISO via
      `just bootstrap-iso <hostname>` for an automated install.

    '';
in {
  # Upstream minimal installation ISO as the base. The bootstrap-install
  # command + source baking are added by installer/default.nix only for
  # host-baked variants.
  imports = [
    "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  users.motd = motd;
  services.getty.helpLine = lib.mkForce helpLine;

  # Disable systemd-boot as we're using ISO bootloader
  boot.loader.systemd-boot.enable = lib.mkForce false;

  # Password root SSH is what `just deploy-remote` (nixos-anywhere) logs into on the
  # generic image; a host-baked image carries the host key and installs at the console.
  services.openssh = {
    enable = !hostBaked;
    settings = lib.mkIf (!hostBaked) {
      PermitRootLogin = lib.mkForce "yes";
      PasswordAuthentication = lib.mkForce true;
      KbdInteractiveAuthentication = lib.mkForce true;
    };
  };

  users.users.root = lib.mkIf (!hostBaked) {
    initialHashedPassword = lib.mkForce null;
    initialPassword = lib.mkForce "nixos";
  };

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
