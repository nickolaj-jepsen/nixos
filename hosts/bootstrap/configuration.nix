{
  nixos = {
    config,
    pkgs,
    lib,
    inputs,
    ...
  }: let
    targetHost = config.fireproof.bootstrap.targetHost;
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
    # Use the nixos installation ISO as base. (bootstrap-install is a dendritic
    # leaf selected via the base aspect, gated on bootstrap.targetHost.)
    imports = [
      "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
    ];

    users.motd = motd;
    services.getty.helpLine = lib.mkForce helpLine;

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
  };
}
