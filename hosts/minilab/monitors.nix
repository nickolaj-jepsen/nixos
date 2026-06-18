# minilab's monitor layout, set as the `monitors` fact (shared into both evals).
{
  shared.fireproof.monitors = [
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
  ];
}
