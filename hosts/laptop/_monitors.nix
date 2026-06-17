# Bare monitor list, consumed as the `monitors` fact in hosts/default.nix.
[
  {
    name = "eDP-1";
    resolution = {
      width = 1920;
      height = 1080;
    };
    refreshRate = 60;
    refreshRateNiri = 60.0;
  }
]
