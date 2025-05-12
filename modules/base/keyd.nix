_: {
  services.keyd = {
    enable = true;
    keyboards.mouse = {
      ids = [
        "046d:c051:4ae65a29"  # Work mouse
      ];
      settings = {
        main = {
          # Bind mouse-back to meta if held
          mouse1 = "overload(meta, mouse1)";
        };
      };
    };
  };
}
