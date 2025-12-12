{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    environment.systemPackages = with pkgs; [
      nautilus
      gnome-photos
    ];

    services.gvfs.enable = true;
    programs = {
      dconf.enable = true;
      nautilus-open-any-terminal.enable = true;
      seahorse.enable = true;
      evince.enable = true;
    };

    services.gnome.sushi.enable = true;

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
        iconTheme = {
          name = "Qogir-dark";
          package = pkgs.qogir-icon-theme;
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
  };
}
