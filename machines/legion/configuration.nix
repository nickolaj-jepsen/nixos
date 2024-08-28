# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, username, inputs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./nvidia.nix
    ];

  # Bootloader.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/nvme0n1";
  boot.loader.grub.useOSProber = true;

  environment.sessionVariables = {
    WLR_NO_HARDWARE_CURSORS = "1";
    NIXOS_OZONE_WL = "1";
  };

  programs.hyprland.enable = true;
  programs.hyprland.xwayland.enable = true;
  
	services.automatic-timezoned.enable = true;

  virtualisation.docker.enable = true;

  fonts.packages = with pkgs; [
    (nerdfonts.override { fonts = [ "Hack" ]; })
  ];

  home-manager.users.${username}.imports = [
    ./home-manager.nix
  ];
  
  environment.systemPackages = [
    pkgs.gtk3
  ];

  networking.wireless.enable = true;
  networking.wireless.networks = {
    Brother = {
      psk = "fireproof";
    };
    "Drakenvej12-5G-1" = {
      psk = "Eg9928nt.";
    };
  };
}
