# Enabled when: desktop
{
  config,
  lib,
  pkgs,
  ...
}: let
  c = config.fireproof.theme.colors;
in {
  config = lib.mkIf config.fireproof.desktop.enable {
    environment.systemPackages = with pkgs; [
      ghostty
    ];
    fireproof.home-manager = {
      programs.ghostty = {
        enable = true;
        enableFishIntegration = config.programs.fish.enable;
        settings = {
          window-decoration = false;
          theme = "fireproof";
          font-size = 11;
          font-family = "Hack Nerd Font";
          window-inherit-font-size = false;
        };
        themes = {
          fireproof = {
            background = c.bg;
            cursor-color = c.fg;
            foreground = c.fg;
            palette = [
              "0=#${c.black}"
              "1=#${c.redAlt}"
              "2=#${c.greenAlt}"
              "3=#${c.yellowAlt}"
              "4=#${c.blueAlt}"
              "5=#${c.magentaAlt}"
              "6=#${c.cyanAlt}"
              "7=#${c.fg}"
              "8=#${c.muted}"
              "9=#${c.red}"
              "10=#${c.green}"
              "11=#${c.yellow}"
              "12=#${c.blue}"
              "13=#${c.magenta}"
              "14=#${c.cyan}"
              "15=#${c.whiteAlt}"
            ];
            selection-background = c.uiAlt;
            selection-foreground = c.fg;
          };
        };
      };
    };
    fireproof.base.defaults.terminal = "ghostty";
  };
}
