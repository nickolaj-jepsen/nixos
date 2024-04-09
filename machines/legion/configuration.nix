# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, username, inputs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Bootloader.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/nvme0n1";
  boot.loader.grub.useOSProber = true;

  environment.sessionVariables = {
    WLR_NO_HARDWARE_CURSORS = "1";
  };

  programs.hyprland.enable = true;
  programs.hyprland.package = inputs.hyprland.packages.${pkgs.system}.hyprland;
  programs.hyprland.xwayland.enable = true;

  home-manager.users.${username}.imports = [
    ./home-manager.nix
  ];
  
  environment.systemPackages = [
    pkgs.gtk3
  ];

  hardware.opengl = {
    enable = true;
    driSupport = true;
  };
  
  networking.wireless.enable = true;
  networking.wireless.networks = {
    Brother = {
      psk = "fireproof";
    };
  };
}
