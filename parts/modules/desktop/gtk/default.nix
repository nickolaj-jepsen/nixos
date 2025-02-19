{
  pkgs,
  ...
}: {
  environment.systemPackages = with pkgs; [
    nautilus
  ];

  fireproof.home-manager = {
    home.pointerCursor = {
      gtk.enable = true;
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
      size = 24;
    };

    gtk = {
      enable = true;
      theme = {
        name = "adw-gtk3-dark";
        package = pkgs.adw-gtk3;
      };

      gtk4.extraCss = builtins.readFile ./theme.css;
      gtk3.extraCss = builtins.readFile ./theme.css;
    };
  };
}
