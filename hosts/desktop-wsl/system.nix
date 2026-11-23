{
  nixos = {lib, ...}: {
    # Windows: `usbipd bind --busid <id>` once per key. Busids are per-port;
    # use `usbipd list` and update this after moving ports. While attached the key
    # is invisible to Windows; `usbipd detach` restores WebAuthn/Windows Hello.
    wsl.usbip.autoAttach = ["1-10"];

    # No GUI apps run here: NixOS-WSL's WSLg default only buys ~270 MB of mesa.
    hardware.graphics.enable = lib.mkForce false;
    documentation.nixos.enable = false;
    documentation.doc.enable = false;
    documentation.info.enable = false;
  };
}
