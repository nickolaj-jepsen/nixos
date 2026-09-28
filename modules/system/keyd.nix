{
  flake.modules.nixos.keyd = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      services.keyd = {
        enable = lib.mkDefault true;
        keyboards.mouse = {
          ids = [
            "046d:c051:4ae65a29" # Work mouse
            "046d:407f:ee6ee407" # Home mouse
            "046d:c547:3a5dd700" # Home mouse (USB receiver)
            "046d:c098:c9d1afa0" # Home mouse (USB cable)
          ];
          settings = {
            main = {
              # Bind mouse back/forward to meta if held
              mouse1 = "overload(meta, mouse1)";
              mouse2 = "overload(meta, mouse2)";
            };
          };
        };
        keyboards.default = {
          ids = ["*"];
          settings = {
            main = {
              # Rebind capslock to backspace for all keyboards
              capslock = "backspace";
            };
          };
        };
      };
    };
  };
}
