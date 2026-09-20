{
  flake.modules.nixos.usb = {
    config,
    lib,
    ...
  }: {
    # Removable-media automount; WSL only sees usbip devices (the YubiKey), never storage.
    config = lib.mkIf config.fireproof.hardware.physical {
      services.devmon.enable = true;
      services.udisks2.enable = true;
    };
  };
}
