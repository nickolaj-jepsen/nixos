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
              rev = "b94c2e5756b4646051fe64ad8cd36eda33405f8a";
              sha256 = "sha256-jQGYFON13XhjX+Xrnd8kglco8xRJ9G7kkGmswtuEgZw=";
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
