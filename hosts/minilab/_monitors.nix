# Bare monitor list, consumed as the `monitors` fact in hosts/default.nix.
[
  {
    name = "DP-2";
    resolution = {
      width = 1920;
      height = 1200;
    };
    refreshRate = 60;
    refreshRateNiri = 60.000;
    transform = 1;
  }
]
