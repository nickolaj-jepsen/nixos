{
  flake.modules.nixos.ghostty = _: {
    config = {
      fireproof.base.defaults.terminal = "ghostty";
    };
  };

  flake.modules.homeManager.ghostty = {
    config,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
  in {
    config = {
      programs.ghostty = {
        enable = true;
        package = pkgs.unstable.ghostty;
        enableFishIntegration = config.programs.fish.enable;
        settings = {
          window-decoration = false;
          theme = "fireproof";
          font-size = 11;
          font-family = "Hack Nerd Font";
          window-inherit-font-size = false;
          shell-integration-features = true;
          # Keyboard-first QoL: hide the pointer while typing.
          mouse-hide-while-typing = true;
          copy-on-select = false;
          # Drop the desktop notification fired on every clipboard copy.
          app-notifications = "no-clipboard-copy";
          # niri clips windows to 8px rounded corners; pad the cell grid so
          # glyphs don't touch the clipped edge, and extend the bg into the pad.
          window-padding-balance = true;
          window-padding-color = "extend";
          scrollback-limit = 104857600; # 100 MiB
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
  };
}
