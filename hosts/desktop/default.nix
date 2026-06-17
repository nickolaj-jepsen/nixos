# Selection (aspects + facts) lives in hosts/default.nix. This file holds only
# desktop's nixos-specific settings.
{pkgs, ...}: {
  config = {
    fireproof.desktop.snapcast.enable = true;
    programs.steam.enable = true;
    fireproof.home-manager.home.packages = [pkgs.unstable.runelite];

    facter.reportPath = ./facter.json;
  };
}
