{
  shared.fireproof.monitors = [
    {
      name = "DP-2";
      primary = true;
      resolution = {
        width = 2560;
        height = 1440;
      };
      refreshRateNiri = 170.001;
      vrr = true;
      position = {
        x = 1920;
        y = 0;
      };
    }
    {
      name = "DP-3";
      resolution = {
        width = 2560;
        height = 1440;
      };
      refreshRateNiri = 165.000;
      vrr = true;
      position = {
        x = 4480;
        y = 0;
      };
    }
    {
      name = "HDMI-A-1";
      resolution = {
        width = 1920;
        height = 1080;
      };
      refreshRateNiri = 60.000;
      position = {
        x = 0;
        y = 0;
      };
    }
    # Odyssey G5: cabled but unused.
    {
      name = "DP-1";
      enable = false;
    }
  ];
}
