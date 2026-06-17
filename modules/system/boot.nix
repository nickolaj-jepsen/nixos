{
  flake.aspectTags.boot = ["base"];
  flake.modules.nixos.boot = {lib, ...}: {
    boot.loader.systemd-boot.enable = lib.mkDefault true;
    boot.loader.efi.canTouchEfiVariables = true;
  };
}
