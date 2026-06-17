{
  flake.modules.nixos.battery = _: {
    config = {
      services.upower.enable = true;
    };
  };
}
