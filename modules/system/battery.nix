{
  flake.aspectTags.battery = ["laptop"];
  flake.modules.nixos.battery = _: {
    config = {
      services.upower.enable = true;
    };
  };
}
