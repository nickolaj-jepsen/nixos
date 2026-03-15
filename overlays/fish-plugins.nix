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
        };
    };
  };
}
