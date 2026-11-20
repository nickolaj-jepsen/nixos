# Small extras for pocketnix's GUI windows. There's no GPU: each one draws in
# software, and imv (OpenGL) or ghostty wouldn't start.
{
  shared.fireproof.gui.enable = true;

  nixos = {pkgs, ...}: {
    environment.systemPackages = [
      pkgs.meld
      pkgs.swayimg
      pkgs.qalculate-gtk
    ];
  };
}
