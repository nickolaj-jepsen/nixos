{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    fonts.enableDefaultPackages = true;
    fonts.packages = with pkgs; [
      nerd-fonts.hack
    ];
  };
}
