{
  flake.aspectTags.qt = ["desktop"];
  flake.modules.nixos.qt = _: {
    config = {
      qt = {
        enable = true;
        platformTheme = "gnome";
        style = "adwaita-dark";
      };
    };
  };
}
