{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    environment.systemPackages = [pkgs.wl-clipboard];
  };
}
