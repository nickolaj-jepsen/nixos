_: {
  perSystem = {pkgs, ...}: {
    overlayAttrs = {
      fishPlugins =
        pkgs.fishPlugins
        // {
          to-fish = {
            name = "to-fish";
            src = pkgs.fetchFromGitHub {
              owner = "joehillen";
              repo = "to-fish";
              rev = "52b151cfe67c00cb64d80ccc6dae398f20364938";
              sha256 = "sha256-DfDsU/qY2XdYlkLISIOv02ggHfKEpb+YompNWWjs5/A=";
            };
          };
          theme-bobthefish = {
            name = "theme-bobthefish";
            src = pkgs.fetchFromGitHub {
              owner = "oh-my-fish";
              repo = "theme-bobthefish";
              rev = "e3b4d4eafc23516e35f162686f08a42edf844e40";
              hash = "sha256-cXOYvdn74H4rkMWSC7G6bT4wa9d3/3vRnKed2ixRnuA=";
            };
          };
        };
    };
  };
}
