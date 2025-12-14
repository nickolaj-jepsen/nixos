{
  config,
  lib,
  pkgs,
  ...
}: {
  options.fireproof.desktop.greeter.enable =
    lib.mkEnableOption "greeter"
    // {
      default = config.fireproof.desktop.enable;
    };

  config = lib.mkIf config.fireproof.desktop.greeter.enable {
    services.greetd = {
      enable = true;
      settings = {
        default_session = {
          command = "${pkgs.tuigreet}/bin/tuigreet --user-menu";
        };
      };
    };
  };
}
