{lib, ...}: {
  services.keyd = {
    enable = lib.mkDefault true;
    keyboards.mouse = {
      ids = [
        "046d:c051:4ae65a29" # Work mouse
        "046d:407f:ee6ee407" # Home mouse
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
