{
  flake.modules.nixos.usb = {
    config,
    lib,
    ...
  }: {
    # Removable-media automount; WSL only sees usbip devices (the YubiKey), never storage.
    config = lib.mkIf config.fireproof.hardware.physical {
      services.devmon.enable = true;
      # Nobody waits on it; yields to the apps under load (modules/system/responsiveness.nix).
      systemd.user.services.devmon.serviceConfig.Slice = "background.slice";
      services.udisks2.enable = true;
    };
  };
}
