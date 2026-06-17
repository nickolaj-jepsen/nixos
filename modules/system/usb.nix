{
  flake.aspectTags.usb = ["base"];
  flake.modules.nixos.usb = _: {
    services.devmon.enable = true;
    services.udisks2.enable = true;
  };
}
