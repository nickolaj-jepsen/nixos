{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    nautilus
    gnome-photos
  ];
  
  services.gvfs.enable = true;
  programs.dconf.enable = true;

  services.gnome.sushi.enable = true;
  programs.nautilus-open-any-terminal.enable = true;
  programs.seahorse.enable = true;
  programs.evince.enable = true;

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

      gtk3.extraConfig = {gtk-application-prefer-dark-theme = true;};
      gtk3.extraCss = builtins.readFile ./theme.css;

      gtk4.extraConfig = {gtk-application-prefer-dark-theme = true;};
      gtk4.extraCss = builtins.readFile ./theme.css;
    };
    dconf = {
      enable = true;
      settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";
    };
  };
}
