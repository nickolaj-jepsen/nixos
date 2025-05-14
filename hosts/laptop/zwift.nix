_: {
  programs.zwift.enable = true;
  hardware.nvidia-container-toolkit.enable = true;
  environment.variables = {
    WINE_EXPERIMENTAL_WAYLAND = "1";
  };
}