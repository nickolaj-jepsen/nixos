# Bare monitor list, consumed as the `monitors` fact in hosts/default.nix.
[
  {
    name = "DP-5";
    primary = true;
    resolution = {
      width = 1920;
      height = 1200;
    };
    position = {
      x = 1920;
      y = 0;
    };
  }
  {
    name = "HDMI-A-5";
    resolution = {
      width = 1920;
      height = 1080;
    };
    position = {
      x = 0;
      y = 0;
    };
  }
  {
    name = "DP-4";
    resolution = {
      width = 1920;
      height = 1200;
    };
    position = {
      x = 3840;
      y = 0;
    };
    transform = 1;
  }
]
