{
  nixos = {lib, ...}: {
    wsl.usbip.autoAttach = ["1-10"]; # YubiKey; usbipd busids are per-port

    # No GUI apps run here: NixOS-WSL's WSLg default only buys ~270 MB of mesa.
    hardware.graphics.enable = lib.mkForce false;
    # Never unlocked without a graphical login; gh and git don't use it.
    services.gnome.gnome-keyring.enable = lib.mkForce false;
    documentation.nixos.enable = false;
    documentation.doc.enable = false;
    documentation.info.enable = false;

    system.stateVersion = "25.11";
  };
}
