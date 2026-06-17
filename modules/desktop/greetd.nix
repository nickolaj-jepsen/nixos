{
  flake.modules.nixos.greetd = {
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

    config = {
      services.greetd = {
        enable = true;
        settings = {
          default_session = {
            command = "${pkgs.tuigreet}/bin/tuigreet --user-menu";
          };
        };
      };
    };
  };
}
