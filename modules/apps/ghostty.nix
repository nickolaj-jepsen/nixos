{
  pkgs,
  config,
  ...
}: {
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
          background = "1C1B1A";
          cursor-color = "DAD8CE";
          foreground = "DAD8CE";
          palette = [
            "0=#100F0F"
            "1=#AF3029"
            "2=#66800B"
            "3=#AD8301"
            "4=#205EA6"
            "5=#A02F6F"
            "6=#24837B"
            "7=#DAD8CE"
            "8=#878580"
            "9=#D14D41"
            "10=#879A39"
            "11=#D0A215"
            "12=#4385BE"
            "13=#CE5D97"
            "14=#3AA99F"
            "15=#F2F0E5"
          ];
          selection-background = "403E3C";
          selection-foreground = "DAD8CE";
        };
      };
    };
  };
  fireproof.default-apps = {
    terminal = "ghostty";
  };
}
