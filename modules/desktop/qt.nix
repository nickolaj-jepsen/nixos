{
  config,
  lib,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    qt = {
      enable = true;
      platformTheme = "gnome";
      style = "adwaita-dark";
    };
  };
}
