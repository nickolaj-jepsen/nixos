{
  config,
  lib,
  pkgs,
  ...
}: let
  c = config.fireproof.theme.colors;

  # Generate GTK CSS from centralized theme
  themeCss = ''
    @define-color bg #${c.bg};
    @define-color bg-alt #${c.bgAlt};
    @define-color fg #${c.fg};
    @define-color fg-alt #${c.fgAlt};
    @define-color muted #${c.muted};
    @define-color ui #${c.ui};
    @define-color ui-alt #${c.uiAlt};
    @define-color black #${c.black};
    @define-color accent #${c.accent};
    @define-color red #${c.red};
    @define-color red-alt #${c.redAlt};
    @define-color orange #${c.orange};
    @define-color orange-alt #${c.orangeAlt};
    @define-color yellow #${c.yellow};
    @define-color yellow-alt #${c.yellowAlt};
    @define-color green #${c.green};
    @define-color green-alt #${c.greenAlt};
    @define-color cyan #${c.cyan};
    @define-color cyan-alt #${c.cyanAlt};
    @define-color blue #${c.blue};
    @define-color blue-alt #${c.blueAlt};
    @define-color purple #${c.purple};
    @define-color purple-alt #${c.purpleAlt};
    @define-color magenta #${c.magenta};
    @define-color magenta-alt #${c.magentaAlt};
    @define-color white #${c.white};
    @define-color white-alt #${c.whiteAlt};

    /* Adwaita stuff */
    @define-color accent_color @accent;
    @define-color accent_bg_color @accent;
    @define-color accent_fg_color @fg;

    @define-color window_bg_color @bg;
    @define-color window_fg_color @fg;

    @define-color headerbar_bg_color @bg-alt;
    @define-color headerbar_fg_color @fg;

    @define-color popover_bg_color @bg-alt;
    @define-color popover_fg_color @fg;

    @define-color dialog_bg_color @popover_bg_color;
    @define-color dialog_fg_color @popover_fg_color;

    @define-color sidebar_bg_color @bg-alt;
    @define-color sidebar_fg_color @fg;
    @define-color sidebar_backdrop_color @bg-alt;
    @define-color sidebar_shade_color rgba(0, 0, 0, 0.25);
    @define-color sidebar_border_color rgba(0, 0, 0, 0.36);

    @define-color secondary_sidebar_bg_color @sidebar_backdrop_color;
    @define-color secondary_sidebar_fg_color @fg;
    @define-color secondary_sidebar_backdrop_color @sidebar_backdrop_color;
    @define-color secondary_sidebar_shade_color @sidebar_shade_color;
    @define-color secondary_sidebar_border_color @sidebar_border_color;

    @define-color view_bg_color @bg;
    @define-color view_fg_color @fg;

    @define-color card_bg_color @bg-alt;
    @define-color card_fg_color @fg;

    @define-color thumbnail_bg_color @bg-alt;
    @define-color thumbnail_fg_color @fg;

    @define-color warning_bg_color @red;
    @define-color warning_fg_color @fg;
    @define-color warning_color @red;
    @define-color error_bg_color @red;
    @define-color error_fg_color @fg;
    @define-color error_color @red;
    @define-color success_bg_color @green;
    @define-color success_fg_color @fg;
    @define-color success_color @green;
    @define-color destructive_bg_color @red;
    @define-color destructive_fg_color @fg;
    @define-color destructive_color @red;
  '';
in {
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
        gtk3.extraCss = themeCss;

        gtk4.extraConfig = {gtk-application-prefer-dark-theme = true;};
        gtk4.extraCss = themeCss;
      };
      dconf = {
        enable = true;
        settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";
      };
    };
  };
}
