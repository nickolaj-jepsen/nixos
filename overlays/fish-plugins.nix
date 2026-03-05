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
              rev = "c5efbe05aed81b201454c0ae1190ba91ea1970ac";
              hash = "sha256-12Xd43vy6qQILV/Q5BeoGaul6DsQv5OloCPLXwR6KNU=";
            };
          };
        };
    };
  };
}
