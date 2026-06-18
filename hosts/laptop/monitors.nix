# laptop's monitor layout, set as the `monitors` fact (shared into both evals).
{
  shared.fireproof.monitors = [
    {
      name = "eDP-1";
      resolution = {
        width = 1920;
        height = 1080;
      };
      refreshRate = 60;
      refreshRateNiri = 60.0;
    }
  ];
}
