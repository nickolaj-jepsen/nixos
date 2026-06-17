{
  flake.modules.nixos.yubikey = _: {
    services.pcscd.enable = true;
  };
}
